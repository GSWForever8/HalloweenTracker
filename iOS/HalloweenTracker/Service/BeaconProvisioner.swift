import CoreBluetooth
import CoreLocation
import ObjectiveC

final class BeaconProvisioner: NSObject, CLLocationManagerDelegate, CBCentralManagerDelegate {

    enum ProvError: Error { case bluetoothOff, noPeripheral, writeFailed, timeout, locationDenied, verifyFailed }
    typealias Allocator = () async throws -> (Int, Int)

    // MARK: - Init / Public
    init(allocator: @escaping Allocator) {
        self.allocator = allocator
        super.init()
        location.delegate = self
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startProvisioning(completion: @escaping (Result<Void, Error>) -> Void) {
        self.completion = completion
        log("startProvisioning")
        checkLocationAuthorization()
    }

    // MARK: - State
    private let allocator: Allocator
    private let location = CLLocationManager()
    private var central: CBCentralManager!

    private var targetPeripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?

    private var pendingMajor: Int?
    private var pendingMinor: Int?

    private var completion: ((Result<Void, Error>) -> Void)?
    private var timeoutTimer: Timer?

    private var centralReady = false
    private var locationReady = false

    private var activeConstraint: CLBeaconIdentityConstraint?

    // MARK: - Beacon & GATT IDs (confirm these!)
    private let BEACON_UUID = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
    private let SVC_UUID  = CBUUID(string: "8E400001-7786-43CA-8000-000000000001")
    private let WR_UUID   = CBUUID(string: "8E400003-7786-43CA-8000-000000000003") // optional: will also fall back by properties

    // MARK: - Location auth
    private func checkLocationAuthorization() {
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            log("requestWhenInUseAuthorization")
            location.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationReady = true
            tryStartProvisioningIfReady()
        case .denied, .restricted:
            finish(.failure(ProvError.locationDenied))
        @unknown default:
            finish(.failure(ProvError.locationDenied))
        }
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        log("didChangeAuthorization \(status.rawValue)")
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            locationReady = true
            tryStartProvisioningIfReady()
        case .denied, .restricted:
            finish(.failure(ProvError.locationDenied))
        default: break
        }
    }

    // MARK: - Central
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("central state: \(central.state.rawValue)")
        switch central.state {
        case .poweredOn:
            centralReady = true
            tryStartProvisioningIfReady()
        case .poweredOff:
            centralReady = false
            if completion != nil { finish(.failure(ProvError.bluetoothOff)) }
        default:
            centralReady = false
        }
    }

    private func tryStartProvisioningIfReady() {
        guard centralReady, locationReady else { return }
        startRangingForZeroBeacon()
    }

    // MARK: - Ranging zero-beacon
    private func startRangingForZeroBeacon() {
        let c = CLBeaconIdentityConstraint(uuid: BEACON_UUID, major: 0, minor: 0)
        activeConstraint = c
        log("startRangingBeacons major=0 minor=0")
        location.startRangingBeacons(satisfying: c)
        startOrResetTimeout(seconds: 30) // discovery phase
    }

    func locationManager(_ manager: CLLocationManager,
                         didRange beacons: [CLBeacon],
                         satisfying constraint: CLBeaconIdentityConstraint) {

        if beacons.isEmpty { return }
        // For debug: show what we saw
        beacons.forEach { b in
            log("ranged beacon m:\(b.major) n:\(b.minor) rssi:\(b.rssi) prox:\(b.proximity.rawValue)")
        }

        guard let _ = beacons.first(where: { $0.major.intValue == 0 && $0.minor.intValue == 0 }) else { return }

        log("FOUND zero-beacon, stop ranging")
        location.stopRangingBeacons(satisfying: constraint)

        Task {
            do {
                let (major, minor) = try await allocator()
                self.pendingMajor = major
                self.pendingMinor = minor
                log("allocator -> major:\(major) minor:\(minor)")

                startOrResetTimeout(seconds: 30) // BLE phase
                log("scanForPeripherals SVC \(SVC_UUID)")
                central.scanForPeripherals(withServices: [SVC_UUID], options: nil)
            } catch {
                finish(.failure(error))
            }
        }
    }

    // MARK: - BLE
    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        log("didDiscover \(peripheral.identifier) rssi:\(RSSI)")
        targetPeripheral = peripheral
        peripheral.delegate = self
        central.stopScan()
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log("didConnect \(peripheral.identifier)")
        startOrResetTimeout(seconds: 20)
        peripheral.discoverServices([SVC_UUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("didFailToConnect \(String(describing: error))")
        finish(.failure(error ?? ProvError.noPeripheral))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("didDisconnect \(String(describing: error))")
        finish(.failure(error ?? ProvError.noPeripheral))
    }

    // MARK: - Timeout / finish
    private func startOrResetTimeout(seconds: TimeInterval) {
        timeoutTimer?.invalidate()
        timeoutTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.log("TIMEOUT")
            self?.finish(.failure(ProvError.timeout))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        if let c = activeConstraint {
            location.stopRangingBeacons(satisfying: c)
        }
        if let p = targetPeripheral {
            central.cancelPeripheralConnection(p)
        }
        timeoutTimer?.invalidate()
        timeoutTimer = nil
        let msg: String
        switch result {
        case .success: msg = "finish SUCCESS"
        case .failure(let e): msg = "finish FAILURE \(e)"
        }
        log(msg)
        completion?(result)
        completion = nil
    }

    private func log(_ s: String) {
        print("[BeaconProvisioner] \(s)")
    }
}

// MARK: - CBPeripheralDelegate
extension BeaconProvisioner: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error {
            log("discoverServices error \(error)")
            finish(.failure(error)); return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            log("no services")
            finish(.failure(ProvError.noPeripheral)); return
        }
        services.forEach { log("service: \($0.uuid)") }

        guard let svc = services.first(where: { $0.uuid == SVC_UUID }) else {
            log("target service not found")
            finish(.failure(ProvError.noPeripheral)); return
        }
        peripheral.discoverCharacteristics(nil, for: svc) // discover all to inspect props
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error = error {
            log("discoverCharacteristics error \(error)")
            finish(.failure(error)); return
        }
        guard let chars = service.characteristics, !chars.isEmpty else {
            log("no characteristics")
            finish(.failure(ProvError.noPeripheral)); return
        }

        for c in chars {
            log("char: \(c.uuid) props: \(c.properties)")
        }

        // Prefer explicit WR_UUID; otherwise pick the first char that supports write or writeWithoutResponse
        let explicit = chars.first(where: { $0.uuid == WR_UUID })
        let byProps = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) })

        guard let char = explicit ?? byProps else {
            log("no writable characteristic found")
            finish(.failure(ProvError.noPeripheral)); return
        }

        writeChar = char

        guard let major = pendingMajor, let minor = pendingMinor else {
            finish(.failure(ProvError.writeFailed)); return
        }

        writeMajorMinor(to: peripheral, major: major, minor: minor, char: char)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            log("didWriteValue error \(e)")
            finish(.failure(e)); return
        }
        log("didWriteValue OK")

        // Verification step: re-range for the **new** values briefly.
        guard let major = pendingMajor, let minor = pendingMinor else {
            finish(.success(())); return
        }

        // Try to see the updated beacon for up to ~8s
        verifyUpdatedBeacon(major: major, minor: minor, window: 8.0)
    }
}

// MARK: - Helpers
extension BeaconProvisioner {

    private func writeMajorMinor(to peripheral: CBPeripheral, major: Int, minor: Int, char: CBCharacteristic) {
        // Big-endian payload: [major_hi, major_lo, minor_hi, minor_lo]
        var data = Data()
        data.append(UInt8((major >> 8) & 0xFF))
        data.append(UInt8(major & 0xFF))
        data.append(UInt8((minor >> 8) & 0xFF))
        data.append(UInt8(minor & 0xFF))

        let supportsWrite = char.properties.contains(.write)
        let supportsWriteNR = char.properties.contains(.writeWithoutResponse)

        guard supportsWrite || supportsWriteNR else {
            log("chosen characteristic not writable by props")
            finish(.failure(ProvError.writeFailed)); return
        }

        let writeType: CBCharacteristicWriteType = supportsWrite ? .withResponse : .withoutResponse
        log("writing \(data as NSData) to char \(char.uuid) type: \(writeType == .withResponse ? "withResponse" : "withoutResponse")")

        if writeType == .withoutResponse {
            // iOS won't call didWriteValue when using .withoutResponse — add our own small confirm path.
            peripheral.writeValue(data, for: char, type: .withoutResponse)
            // Give the peripheral a moment and proceed to verification
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard let self = self else { return }
                if let major = self.pendingMajor, let minor = self.pendingMinor {
                    self.verifyUpdatedBeacon(major: major, minor: minor, window: 8.0)
                } else {
                    self.finish(.success(()))
                }
            }
        } else {
            peripheral.writeValue(data, for: char, type: .withResponse)
        }
    }

    private func verifyUpdatedBeacon(major: Int, minor: Int, window: TimeInterval) {
        // Restart ranging for new IDs to confirm update took effect
        let c = CLBeaconIdentityConstraint(uuid: BEACON_UUID,
                                           major: CLBeaconMajorValue(major),
                                           minor: CLBeaconMinorValue(minor))
        activeConstraint = c
        log("verify: startRanging m:\(major) n:\(minor)")
        location.startRangingBeacons(satisfying: c)

        // Windowed verification — if we don't see it, report verifyFailed
        DispatchQueue.main.asyncAfter(deadline: .now() + window) { [weak self] in
            guard let self = self else { return }
            self.log("verify window elapsed — if not already finished, failing")
            // If we already finished due to didRange, this is a no-op.
            if self.completion != nil {
                self.finish(.failure(ProvError.verifyFailed))
            }
        }
    }

    // Hook into ranging to complete verification early when we see the updated IDs.
    func locationManager(_ manager: CLLocationManager,
                         didRange beacons: [CLBeacon],
                         satisfying constraint: CLBeaconIdentityConstraint,
                         // overload name is same; Swift allows this dual use
                         _dummy: Void = ()) {
        // This method will be called for any active constraint; look for the "verify" constraint with nonzero major/minor
        guard let c = activeConstraint else { return }
        let targetMajor = c.major.map { Int($0) } ?? 0
        let targetMinor = c.minor.map { Int($0) } ?? 0
        guard targetMajor > 0 || targetMinor > 0 else { return }

        if let hit = beacons.first(where: { $0.major.intValue == targetMajor && $0.minor.intValue == targetMinor }) {
            log("verify: saw updated beacon m:\(hit.major) n:\(hit.minor)")
            finish(.success(()))
        }
    }
}
