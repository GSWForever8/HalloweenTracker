//
//  Device.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import Foundation
import SwiftData

@Model
final class TrackerDevice {
    @Attribute(.unique) var bleId: UUID
    var name: String
    var ownerUID: String
    var pairedAt: Date
    var isActive: Bool
    var lastSeenAt: Date?
    var lastRSSI: Int?
    var lastBatteryPercent: Int?
    var beaconMajor: Int
    var beaconMinor: Int
    var lat: Double?
    var lng: Double?
    @Attribute(.unique) var beaconKey: String

    init(bleId: UUID, name: String, ownerUID: String, major: Int, minor: Int) {
        self.bleId = bleId
        self.name = name
        self.ownerUID = ownerUID
        self.pairedAt = Date()
        self.isActive = true
        self.beaconMajor = major
        self.beaconMinor = minor
        self.beaconKey = "\(major)-\(minor)"
        self.lat = lat
        self.lng = lng
        self.lastRSSI = 1
    }
    func updateBeacon(major: Int, minor: Int) {
        self.beaconMajor = major
        self.beaconMinor = minor
        self.beaconKey = "\(major)-\(minor)"
    }
}
