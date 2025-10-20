//
//  ProfileView.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import SwiftUI
import SwiftData
import Combine

struct ProfileView: View {
    @EnvironmentObject var auth: AuthManager
    @Environment(\.modelContext) private var context
    @Query(sort: \TrackerDevice.pairedAt, order: .reverse) private var trackers: [TrackerDevice]
    @State private var isSyncing = false
    let ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var settingPopover = false
    @State private var addPopover = false
    @State private var syncer: SyncManager?
    @State private var provisioning = false
    @State private var provisionError: String?
    @State private var reporter: ProximityReporter?

    var body: some View {
        NavigationStack {
                List {
                    // ... (your header section unchanged)
                    Section("Your Trackers") {
                        if trackers.isEmpty {
                            ContentUnavailableView(
                                "No trackers yet",
                                systemImage: "dot.radiowaves.left.and.right",
                                description: Text("Tap + to add your first tracker.")
                            )
                        } else {
                            ForEach(trackers) { t in
                                NavigationLink {
                                    TrackerView(lat:t.lat ?? 0, lng:t.lng ?? 0).navigationTitle(t.name+"'s Location")
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(t.name).font(.headline)
                                        HStack(spacing: 10) {
                                            if let seen = t.lastSeenAt {
                                                Text("Last seen \(seen.formatted(date: .omitted, time: .shortened))")
                                            } else {
                                                Text("Never seen")
                                            }
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .onDelete(perform: deleteTrackers)
                        }
                    }
                    
                }
                .navigationTitle("My Devices")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            settingPopover = true
                        } label: {
                            Image(systemName: "gear")
                        }
                        .accessibilityLabel("Settings")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            addPopover = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add Tracker")
                    }
                }
                .onReceive(ticker) { _ in
                    guard !isSyncing else { return }
                    isSyncing = true
                    Task {
                        await syncer?.syncAll(fetchPings: true)
                        isSyncing = false
                    }
                }
                .refreshable {
                    await syncer?.syncAll(fetchPings: true)
                }
                .sheet(isPresented: $settingPopover) {
                    SettingsView()
                        .padding()
                        .presentationDetents([.medium, .large])
                }
                .sheet(isPresented: $addPopover) {
                    AddTrackerSheet { name in
                        addTracker(name: name)
                        print("Should be done")
                        Task { await syncer?.syncAll(fetchPings: false) } // push new device
                    }
                    .padding()
                    .presentationDetents([.medium, .large])
                }
                .task {
                    // Initialize syncer once we have context + auth
                    if syncer == nil {
                        // Point this to your dev server; use LAN IP on iPhone/iPad
                        let base = URL(string: "http://192.168.50.171:3000")!
                        syncer = SyncManager(
                            context: context,
                            baseURL: base,
                            ownerUIDProvider: { auth.userID }
                        )
                    }
                    await syncer?.syncAll(fetchPings: true)
                    reporter = ProximityReporter(userID: auth.userID)
                    reporter?.start()
                }
            }
    }

    private var profileTitle: String { auth.userID.isEmpty ? "You" : auth.userID }

    private struct MajorRes: Decodable { let major: Int }
    private struct NextMinorRes: Decodable { let nextMinor: Int }

    private func addTracker(name: String, major: Int? = nil, minor: Int? = nil) {
        Task {
            do {
                // 1) Fetch major (only if needed)
                var resolvedMajor = major
                print(resolvedMajor)
                if resolvedMajor == nil {
                    let majorURL = URL(string: "http://192.168.50.171:3000/majorGivenUID/")!
                    var req = URLRequest(url: majorURL)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["uid": auth.userID])
                    
                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        print("❌ major request failed with status:", (resp as? HTTPURLResponse)?.statusCode ?? -1)
                        return
                    }
                    let decoded = try JSONDecoder().decode(MajorRes.self, from: data)
                    resolvedMajor = decoded.major
                    print("Fetched major:", decoded.major)
                }
                print(resolvedMajor)
                // 2) Fetch next minor (only if needed)
                var resolvedMinor = minor
                print(resolvedMinor)
                if resolvedMinor == nil {
                    let minorURL = URL(string: "http://192.168.50.171:3000/getNextMinor/")!
                    var req = URLRequest(url: minorURL)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["uid": auth.userID])

                    let (data, resp) = try await URLSession.shared.data(for: req)
                    guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                        print("❌ minor request failed with status:", (resp as? HTTPURLResponse)?.statusCode ?? -1)
                        return
                    }
                    let decoded = try JSONDecoder().decode(NextMinorRes.self, from: data)
                    resolvedMinor = decoded.nextMinor
                    print("Fetched minor:", decoded.nextMinor)
                }
                print(resolvedMinor)
                guard let finalMajor = resolvedMajor, let finalMinor = resolvedMinor else {
                    print("❌ Could not resolve major/minor")
                    return
                }
                // After allocation, configure the physical tracker via BLE
                let prov = BeaconProvisioner(allocator: { (finalMajor, finalMinor) })
                Task {
                    await MainActor.run {
                        provisioning = true
                    }
                    prov.startProvisioning(with: finalMajor, minor: finalMinor) { result in
                        DispatchQueue.main.async {
                            provisioning = false
                            switch result {
                            case .success:
                                print("✅ Tracker BLE configured with \(finalMajor)-\(finalMinor)")
                            case .failure(let err):
                                print("❌ BLE provisioning failed:", err)
                            }
                        }
                    }
                }

                // 3) Insert + save on main thread (SwiftData safety)
                try await MainActor.run {
                    let device = TrackerDevice(
                        bleId: UUID(),
                        name: name.isEmpty ? "Pumpkin-\(Int.random(in: 1...999))" : name,
                        ownerUID: auth.userID.isEmpty ? "parent-local" : auth.userID,
                        major: finalMajor,
                        minor: finalMinor,
                    )
                    context.insert(device)
                    try context.save()
                }
                print("✅ Tracker created with major \(finalMajor), minor \(finalMinor)")
            } catch {
                print("❌ Error adding tracker:", error)
            }
        }

    }
    private func deleteTrackers(at offsets: IndexSet) {
        // 1) Capture targets first (indexes may shift after deletes)
        let targets = offsets.map { trackers[$0] }

        // 2) Delete locally (sync) with animation
        withAnimation {
            for t in targets {
                context.delete(t)
            }
            do {
                try context.save()
            } catch {
                context.undoManager?.undo()
                print("❌ Failed to delete locally: \(error)")
            }
        }

        // 3) Notify backend (async), one request per deleted device
        Task {
            for t in targets {
                await sendDeleteToServer(major: t.beaconMajor, minor: t.beaconMinor)
            }
        }
    }

    private func sendDeleteToServer(major: Int, minor: Int) async {
        guard let url = URL(string: "http://192.168.50.171:3000/deleteDevice") else {
            print("❌ Bad URL")
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Either JSONEncoder or JSONSerialization works; JSONEncoder is cleaner here.
        struct Payload: Encodable { let major: Int; let minor: Int }
        do {
            req.httpBody = try JSONEncoder().encode(Payload(major: major, minor: minor))
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                print("❌ Server delete failed, status:", (resp as? HTTPURLResponse)?.statusCode ?? -1)
                return
            }
            print("✅ Deleted on server: major=\(major), minor=\(minor)")
        } catch {
            print("❌ Network error deleting on server:", error)
        }
    }
}
struct AddTrackerSheet: View {
    /// Called when the user taps "Save"
    var onSave: (String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Tracker")
                .font(.title3)
                .bold()
            
            TextField("Name (e.g., Pumpkin-1)", text: $name)
                .textFieldStyle(.roundedBorder)
                .autocapitalization(.none)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(name)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .frame(minWidth: 320)
        .padding()
    }

    /// Helper: parses both decimal and hex strings like "0x1234"
    private func parseInt(_ s: String) -> Int? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x"), let val = Int(trimmed.dropFirst(2), radix: 16) {
            return val
        }
        return Int(trimmed)
    }
}
#Preview{
    ProfileView().environmentObject(AuthManager())
}
