//
//  BeaconLEDController.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/27/25.
//  Drives ESP32 LED color via BLE characteristic (0 = NEAR, 1 = FAR).
//

import Foundation
import CoreBluetooth

final class BeaconLEDController: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var central: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    private var ledChar: CBCharacteristic?

    // Must match ESP32 service/char UUIDs
    private let serviceUUID = CBUUID(string: "8E400001-7786-43CA-8000-000000000001")
    private let ledCharUUID = CBUUID(string: "8E400004-7786-43CA-8000-000000000004")

    private var pendingValue: UInt8? = nil
    private var isScanning = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func setProximity(isFar: Bool) {
        let val: UInt8 = isFar ? 1 : 0
        if let char = ledChar, let p = targetPeripheral {
            p.writeValue(Data([val]), for: char, type: .withoutResponse)
        } else {
            pendingValue = val
            if central.state == .poweredOn { startScanIfNeeded() }
        }
    }

    // MARK: CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            startScanIfNeeded()
        } else {
            stopScan()
            if let p = targetPeripheral {
                self.central.cancelPeripheralConnection(p)
            }
            targetPeripheral = nil
            ledChar = nil
        }
    }

    private func startScanIfNeeded() {
        guard !isScanning, targetPeripheral == nil else { return }
        isScanning = true
        central.scanForPeripherals(
            withServices: [serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func stopScan() {
        if isScanning {
            central.stopScan()
            isScanning = false
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {
        // Connect to the first matching peripheral
        targetPeripheral = peripheral
        stopScan()
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else { return }
        peripheral.discoverCharacteristics([ledCharUUID], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        ledChar = service.characteristics?.first(where: { $0.uuid == ledCharUUID })
        if let val = pendingValue, let ch = ledChar {
            pendingValue = nil
            peripheral.writeValue(Data([val]), for: ch, type: .withoutResponse)
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if peripheral == targetPeripheral {
            ledChar = nil
            targetPeripheral = nil
            startScanIfNeeded() // keep retrying
        }
    }
}
