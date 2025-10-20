//
//  BeaconProvisioner.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/19/25.
//

import ObjectiveC
import CoreLocation
import CoreBluetooth
let BEACON_UUID = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
let SVC_UUID  = CBUUID(string: "8E400001-7786-43CA-8000-000000000001")
let RD_UUID   = CBUUID(string: "8E400002-7786-43CA-8000-000000000002") // read {maj,min,txp}
let WR_UUID   = CBUUID(string: "8E400003-7786-43CA-8000-000000000003")

final class BeaconProvisioner: NSObject {
    enum ProvError: Error { case bluetoothOff, noPeripheral, writeFailed, timeout, locationDenied }
    
    private let location = CLLocationManager()
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var readChar: CBCharacteristic?
    private var pendingMajor: Int?
    private var pendingMinor: Int?
    // External dependency you supply (calls your Flask backend)
    // Return the correct (major, minor) for the current user
    typealias Allocator = () async throws -> (Int, Int)
    private let allocator: Allocator
    
    // Control
    private var provisionOnce = false
    private var completion: ((Result<Void, Error>) -> Void)?
    private var timeoutTimer: Timer?
    
    init(allocator: @escaping Allocator) {
        self.allocator = allocator
        super.init()
        self.location.delegate = self
        self.central = CBCentralManager(delegate: self, queue: .main)
    }
    
    /// Entry point: look for (0,0) beacon, then provision it over BLE.
    func startProvisioning(with major: Int, minor: Int,
                           completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        self.completion = completion
        self.pendingMajor = major
        self.pendingMinor = minor
        
        if central.state == .poweredOn {
            startBleScan()
        }
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: false) { [weak self] _ in
            self?.finish(.failure(ProvError.timeout))
        }
    }
    
    private func startRanging() {
        let region = CLBeaconRegion(uuid: BEACON_UUID, identifier: "tracker-family")
        location.startRangingBeacons(satisfying: CLBeaconIdentityConstraint(uuid: region.uuid))
    }
    
    private func stopRanging() {
        location.stopRangingBeacons(satisfying: CLBeaconIdentityConstraint(uuid: BEACON_UUID))
    }
    
    private func startBleScan() {
        // Filter by service UUID (ESP32 advertises it in scan response)
        central.scanForPeripherals(withServices: [SVC_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }
    
    private func stopBleScan() { central.stopScan() }
    
    private func finish(_ result: Result<Void, Error>) {
        stopRanging()
        stopBleScan()
        if let p = targetPeripheral { central.cancelPeripheralConnection(p) }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        completion?(result)
        completion = nil
    }
}

// MARK: - CLLocationManagerDelegate
extension BeaconProvisioner: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying constraint: CLBeaconIdentityConstraint) {
        guard !provisionOnce else { return }
        // Pick nearest beacon with (0,0)
        if let b = beacons
            .filter({ $0.uuid == BEACON_UUID && $0.major.intValue == 0 && $0.minor.intValue == 0 })
            .sorted(by: { $0.rssi > $1.rssi })
            .first {
            provisionOnce = true
            stopRanging()
            // Allocate on server, then do BLE write
            Task {
                do {
                    let (major, minor) = try await allocator()
                    // Begin BLE scan/connect/write
                    startBleScan()
                    // We’ll write after discovering the peripheral/characteristics
                    // Store the pair temporarily on the instance:
                    pendingMajor = major
                    pendingMinor = minor
                } catch {
                    finish(.failure(error))
                }
            }
        }
    }
}

// Store pending pair to write after BLE discovery
private var pendingMajor: Int = 0
private var pendingMinor: Int = 0

// MARK: - CBCentralManagerDelegate
extension BeaconProvisioner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            completion?(.failure(BeaconProvisioner.ProvError.bluetoothOff))
        } else if completion != nil {
            startRanging()
        }
    }
    
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        // First one advertising our service: connect
        stopBleScan()
        targetPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([SVC_UUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        finish(.failure(error ?? ProvError.noPeripheral))
    }
}

// MARK: - CBPeripheralDelegate
extension BeaconProvisioner: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let e = error { finish(.failure(e)); return }
        guard let svc = peripheral.services?.first(where: { $0.uuid == SVC_UUID }) else {
            finish(.failure(ProvError.noPeripheral)); return
        }
        peripheral.discoverCharacteristics([WR_UUID, RD_UUID], for: svc)
    }
    
    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let e = error { finish(.failure(e)); return }
        for c in service.characteristics ?? [] {
            if c.uuid == WR_UUID { writeChar = c }
            if c.uuid == RD_UUID { readChar  = c }
        }
        guard let w = writeChar else { finish(.failure(ProvError.noPeripheral)); return }
        
        // Build 4-byte big-endian payload
        var data = Data(capacity: 4)
        data.append(UInt8((pendingMajor! >> 8) & 0xFF))
        data.append(UInt8(pendingMajor! & 0xFF))
        data.append(UInt8((pendingMinor! >> 8) & 0xFF))
        data.append(UInt8(pendingMinor! & 0xFF))
        
        peripheral.writeValue(data, for: w, type: .withResponse)
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { finish(.failure(e)); return }
        // Optional: verify by reading back
        if let r = readChar { peripheral.readValue(for: r) }
        else { finish(.success(())) }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { finish(.failure(e)); return }
        // Expect 5 bytes: maj_hi, maj_lo, min_hi, min_lo, txp
        if let v = characteristic.value, v.count == 5 {
            // You could parse and sanity-check here if desired
        }
        finish(.success(()))
    }
}
