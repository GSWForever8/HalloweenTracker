//
//  Sync.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/17/25.
//

import Foundation
import UserNotifications
import SwiftData

// MARK: - DTOs that match your Flask JSON

struct DeviceDTO: Codable, Hashable {
    var bleId: String
    var name: String
    var ownerUID: String
    var pairedAt: String
    var isActive: Bool
    var lastSeenAt: String?
    var lastRSSI: Int?
    var lastBatteryPercent: Int?
    var beaconMajor: Int
    var beaconMinor: Int
    var lat: Double?
    var lng: Double?
}

// MARK: - Simple backend client for your Flask API

final class BackendClient {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    private func makeRequest(path: String, method: String = "GET", body: Any? = nil) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        return req
    }

    private func ensureOK(_ resp: URLResponse) throws {
        guard let r = resp as? HTTPURLResponse, (200..<300).contains(r.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }

    // ---- Devices ----
    func listDevices() async throws -> [DeviceDTO] {
        let (data, resp) = try await URLSession.shared.data(for: try makeRequest(path: "devices"))
        try ensureOK(resp)
        return try JSONDecoder().decode([DeviceDTO].self, from: data)
    }

    func createDevice(_ d: DeviceDTO) async throws {
        let payload: [String: Any] = [
            "bleId": d.bleId,
            "name": d.name,
            "ownerUID": d.ownerUID,
            "isActive": d.isActive,
            "lastSeenAt": d.lastSeenAt as Any,
            "lastRSSI": d.lastRSSI as Any,
            "lastBatteryPercent": d.lastBatteryPercent as Any,
            "beaconMajor": d.beaconMajor,
            "beaconMinor": d.beaconMinor
        ]
        let (_, resp) = try await URLSession.shared.data(for: try makeRequest(path: "devices", method: "POST", body: payload))
        try ensureOK(resp)
    }
}
// MARK: - Notifications

private func postPickupNotifyNow(name: String) {
    let content = UNMutableNotificationContent()
    content.title = "Pickup requested"
    content.body = name+" is asking to be picked up."
    let req = UNNotificationRequest(identifier: "pickup-\(UUID().uuidString)",
                                    content: content,
                                    trigger: nil)
    UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
}


// MARK: - Helpers

private let iso8601Z: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func parseISO(_ s: String?) -> Date? {
    guard let s else { return nil }
    // try with and without fractional seconds
    if let d = iso8601Z.date(from: s) { return d }
    let f2 = ISO8601DateFormatter()
    f2.formatOptions = [.withInternetDateTime]
    return f2.date(from: s)
}

// MARK: - Sync Manager

@MainActor
final class SyncManager {
    private let context: ModelContext
    private let api: BackendClient
    private let ownerUIDProvider: () -> String
    
    /// - Parameters:
    ///   - baseURL: e.g. http://192.168.1.23:5000 in device testing or your deployed HTTPS URL
    ///   - apiKey: match your Flask API key if set
    ///   - ownerUIDProvider: closure that returns current user id (from AuthManager)
    init(context: ModelContext, baseURL: URL, apiKey: String? = nil, ownerUIDProvider: @escaping () -> String) {
        self.context = context
        self.api = BackendClient(baseURL: baseURL)
        self.ownerUIDProvider = ownerUIDProvider
    }
    
    // High-level entry point
    func syncAll(fetchPings: Bool = false) async {
        do {
            // 1) Down-sync devices
            let serverDevices = try await api.listDevices()
            try mergeServerDevices(serverDevices)
            
            // 2) Up-sync any local devices that the server doesn't have yet
            try await pushNewLocalDevices(serverKnown: Set(serverDevices.map { $0.bleId }))
            
            // 3) (Optional) fetch recent pings and merge
        } catch {
            print("Sync failed:", error)
        }
    }
    
    // MARK: Down-merge devices
    private func mergeServerDevices(_ list: [DeviceDTO]) throws {
        // Build an index of existing local devices by bleId
        let fetch = FetchDescriptor<TrackerDevice>()
        let locals = try context.fetch(fetch)
        var byId: [String: TrackerDevice] = [:]
        for d in locals { byId[d.bleId.uuidString.lowercased()] = d }
        
        for s in list {
            let key = s.bleId.lowercased()
            if let local = byId[key] {
                // update existing
                local.name = s.name
                local.ownerUID = s.ownerUID
                local.isActive = s.isActive
                local.beaconMajor = s.beaconMajor
                local.beaconMinor = s.beaconMinor
                if let ls = parseISO(s.lastSeenAt) { local.lastSeenAt = ls } else { local.lastSeenAt = nil }
                local.lastRSSI = s.lastRSSI
                local.lastBatteryPercent = s.lastBatteryPercent
                local.lat = s.lat
                local.lng = s.lng
                local.lastRSSI = s.lastRSSI
                // pairedAt from server if we have it
                if let pAt = parseISO(s.pairedAt) { local.pairedAt = pAt }
                if s.lastRSSI == 0{
                    postPickupNotifyNow(name: local.name)
                }
            } else {
                // insert new
                guard let ble = UUID(uuidString: s.bleId) else { continue }
                let dev = TrackerDevice(
                    bleId: ble,
                    name: s.name,
                    ownerUID: s.ownerUID,
                    major: s.beaconMajor,
                    minor: s.beaconMinor
                )
                dev.isActive = s.isActive
                dev.lastRSSI = 1
                dev.lastBatteryPercent = s.lastBatteryPercent
                if let ls = parseISO(s.lastSeenAt) { dev.lastSeenAt = ls }
                if let pAt = parseISO(s.pairedAt) { dev.pairedAt = pAt }
                context.insert(dev)
            }
        }
        try context.save()
    }
    
    // MARK: Up-sync devices not present on server
    private func pushNewLocalDevices(serverKnown: Set<String>) async throws {
        let locals = try context.fetch(FetchDescriptor<TrackerDevice>())
        for d in locals {
            let id = d.bleId.uuidString
            if !serverKnown.contains(id) {
                let dto = DeviceDTO(
                    bleId: id,
                    name: d.name,
                    ownerUID: d.ownerUID,
                    pairedAt: iso8601Z.string(from: d.pairedAt),
                    isActive: d.isActive,
                    lastSeenAt: d.lastSeenAt.map { iso8601Z.string(from: $0) },
                    lastRSSI: d.lastRSSI,
                    lastBatteryPercent: d.lastBatteryPercent,
                    beaconMajor: d.beaconMajor,
                    beaconMinor: d.beaconMinor
                )
                try await api.createDevice(dto)
            }
        }
    }
}
