//
//  ProximityReporter.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/19/25.
//

import Foundation
import CoreLocation

final class ProximityReporter: NSObject, CLLocationManagerDelegate {
    private let location = CLLocationManager()
    private var timer: Timer?
    private let uploadURL = URL(string: "http://192.168.50.171:3000/devices/ping")!
    private let userID: String
    private let beaconUUID = BEACON_UUID
    private var isRunning = false

    init(userID: String) {
        self.userID = userID
        super.init()
        location.delegate = self
        location.requestWhenInUseAuthorization()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        startRanging()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.performScanAndUpload()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        stopRanging()
    }

    // MARK: - Ranging
    private func startRanging() {
        let constraint = CLBeaconIdentityConstraint(uuid: beaconUUID)
        location.startRangingBeacons(satisfying: constraint)
    }

    private func stopRanging() {
        let constraint = CLBeaconIdentityConstraint(uuid: beaconUUID)
        location.stopRangingBeacons(satisfying: constraint)
    }

    private var lastBeacons: [CLBeacon] = []

    func locationManager(_ manager: CLLocationManager, didRange beacons: [CLBeacon], satisfying constraint: CLBeaconIdentityConstraint) {
        lastBeacons = beacons
    }

    // MARK: - Upload
    private func performScanAndUpload() {
        guard let nearest = lastBeacons.sorted(by: { $0.rssi > $1.rssi }).first else { return }
        let rssi = nearest.rssi

        // Only upload if signal is strong (near)
        guard rssi > -70 else { return }

        // Fetch GPS
        location.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        uploadLocation(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error:", error)
    }

    private func uploadLocation(lat: Double, lng: Double) {
        guard let nearest = lastBeacons.sorted(by: { $0.rssi > $1.rssi }).first else { return }
        let major = nearest.major.intValue
        let minor = nearest.minor.intValue

        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "uid": userID,
            "major": major,
            "minor": minor,
            "lat": lat,
            "lng": lng,
            "timestamp": Date().ISO8601Format()
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { print("❌ Upload error:", err); return }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                print("⚠️ Upload failed, status \(http.statusCode)")
            } else {
                print("✅ Uploaded location for \(major)-\(minor)")
            }
        }.resume()
    }
}
