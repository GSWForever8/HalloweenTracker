//
//  ProximityReporter.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/19/25.
//  Updated: added UNUserNotificationCenter delegate for foreground alerts.
//

import Foundation
import CoreLocation
import CoreBluetooth
import UserNotifications
import UIKit

final class ProximityReporter: NSObject, CLLocationManagerDelegate, UNUserNotificationCenterDelegate {
    private let location = CLLocationManager()
    private var foregroundTimer: Timer?
    private let uploadURL = URL(string: "http://192.168.86.26:3000/devices/pings")!
    private let userID: String

    private let beaconUUID = UUID(uuidString: "E2C56DB5-DFFB-48D2-B060-D0F5A71096E0")!
    private lazy var region = CLBeaconRegion(uuid: beaconUUID, identifier: "tracker-region")

    private var isRunning = false
    private var lastBeacons: [CLBeacon] = []
    private var lastNotifiedSendHome = false
    private var lastMajor: Int?
    private var lastMinor: Int?
    private var lastSafetyIsSafe: Bool? // to avoid spamming identical posts
    private var safe = 1
    private let ledCtrl = BeaconLEDController()
    private var lastIsFar: Bool? = nil

    // Background upload support
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: - Init
    init(userID: String) {
        self.userID = userID
        super.init()

        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        location.pausesLocationUpdatesAutomatically = true
        location.allowsBackgroundLocationUpdates = true

        // 🔔 Notifications setup
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, err in
            print("🔐 Notification permission: \(granted), err: \(String(describing: err))")
        }

        // Location permissions
        location.requestAlwaysAuthorization()
    }

    // MARK: - Start/Stop
    func start() {
        guard !isRunning else { return }
        isRunning = true
        configureRangingAndMonitoring()
        startForegroundTimer()
    }

    func stop() {
        isRunning = false
        stopForegroundTimer()
        stopRanging()
        stopMonitoring()
    }

    // MARK: - Notifications
    private func notifySendHome(name: String) {
        let content = UNMutableNotificationContent()
        content.title = "Pickup requested"
        content.body = name + " is asking to be picked up."
        print("🔔 sendHome=true → calling notifySendHome()")
        let req = UNNotificationRequest(identifier: "pickup-\(UUID().uuidString)",
                                        content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    // Show notifications while app is in foreground
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // MARK: - Authorization
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = CLLocationManager.authorizationStatus()
        guard isRunning else { return }
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            configureRangingAndMonitoring()
        case .denied, .restricted:
            stop()
        default: break
        }
    }

    // MARK: - Ranging & Monitoring
    private func configureRangingAndMonitoring() {
        guard CLLocationManager.isRangingAvailable() else { return }
        startMonitoring()
        if UIApplication.shared.applicationState != .background {
            startRanging()
        }
        location.requestState(for: region)
    }

    private func startRanging() {
        let constraint = CLBeaconIdentityConstraint(uuid: beaconUUID)
        location.startRangingBeacons(satisfying: constraint)
    }

    private func stopRanging() {
        let constraint = CLBeaconIdentityConstraint(uuid: beaconUUID)
        location.stopRangingBeacons(satisfying: constraint)
    }

    private func startMonitoring() {
        location.startMonitoring(for: region)
    }

    private func stopMonitoring() {
        location.stopMonitoring(for: region)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        startRanging()
        scheduleOneShotUpload()
    }

    func locationManager(_ manager: CLLocationManager,
                         didDetermineState state: CLRegionState,
                         for region: CLRegion) {
        guard region.identifier == self.region.identifier else { return }
        if state == .inside {
            startRanging()
        }
    }

    // MARK: - Foreground timer
    private func startForegroundTimer() {
        stopForegroundTimer()
        foregroundTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if UIApplication.shared.applicationState != .background {
                self.performScanAndUpload()
            }
        }
    }

    private func stopForegroundTimer() {
        foregroundTimer?.invalidate()
        foregroundTimer = nil
    }

    // MARK: - Ranging results
    func locationManager(_ manager: CLLocationManager,
                         didRange beacons: [CLBeacon],
                         satisfying constraint: CLBeaconIdentityConstraint) {
        lastBeacons = beacons

        if let nearest = beacons.sorted(by: { $0.rssi > $1.rssi }).first {
            let majorVal = nearest.major.intValue
            let rawMinorVal = nearest.minor.intValue

            // ✅ 1) check the high bit on the RAW value
            let sendHomeFlag = (rawMinorVal & 0x8000) != 0

            // ✅ 2) make a clean minor for UI/backend
            let minorVal = rawMinorVal & 0x7FFF

            // store last seen ids
            lastMajor = majorVal
            lastMinor = minorVal

            print("📡 Ranged beacon: major=\(majorVal) minor=\(minorVal) rssi=\(nearest.rssi) sendHome=\(sendHomeFlag)")

            if sendHomeFlag{
                safe=0
            }
            else{
                safe=1
            }
        }

        evaluateAndDriveLED()
    }

    private func evaluateAndDriveLED() {
        guard let nearest = lastBeacons.sorted(by: { $0.rssi > $1.rssi }).first else { return }
        // Far if CL says .far OR RSSI very weak OR unknown
        let isFar = nearest.proximity == .far || nearest.rssi < -85 || nearest.proximity == .unknown
        if lastIsFar != isFar {
            lastIsFar = isFar
            ledCtrl.setProximity(isFar: isFar)
        }
    }

    // MARK: - Upload trigger
    private func scheduleOneShotUpload() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.performScanAndUpload()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.stopRanging()
            }
        }
    }

    private func performScanAndUpload() {
        guard let nearest = lastBeacons.sorted(by: { $0.rssi > $1.rssi }).first else { return }
        guard nearest.proximity == .immediate || (nearest.rssi > -70 && nearest.proximity != .unknown) else { return }
        requestOneFixThenUpload()
    }

    // MARK: - Location burst
    private func requestOneFixThenUpload() {
        location.startUpdatingLocation()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.location.stopUpdatingLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        guard let loc = locs.last else { return }
        location.stopUpdatingLocation()
        uploadLocation(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error:", error)
    }

    // MARK: - Networking
    private func uploadLocation(lat: Double, lng: Double) {
        guard let nearest = lastBeacons.sorted(by: { $0.rssi > $1.rssi }).first else { return }

        let major = nearest.major.intValue
        let rawMinor = nearest.minor.intValue
        let sendHomeFlag = (rawMinor & 0x8000) != 0
        let cleanMinor = rawMinor & 0x7FFF

        var req = URLRequest(url: uploadURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        print(major, cleanMinor, lat, lng, safe, sendHomeFlag)

        let body: [String: Any] = [
            "uid": userID,
            "major": major,
            "minor": cleanMinor,             // <-- 1, not 32769
            "sendHome": sendHomeFlag,        // <-- explicit flag
            "lat": lat,
            "lng": lng,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "last_RSSI": safe
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        beginBGTaskIfNeeded()
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            defer { self?.endBGTaskIfNeeded() }
            if let err = err {
                print("❌ Upload error:", err)
                return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode >= 300 {
                print("⚠️ Upload failed, status \(http.statusCode)")
            } else {
                print("✅ Uploaded \(major)-\(cleanMinor) @ \(lat),\(lng) sendHome=\(sendHomeFlag)")
            }
        }.resume()
    }

    private func beginBGTaskIfNeeded() {
        if bgTask == .invalid {
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "beacon-upload") { [weak self] in
                self?.endBGTaskIfNeeded()
            }
        }
    }

    private func endBGTaskIfNeeded() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }
}
