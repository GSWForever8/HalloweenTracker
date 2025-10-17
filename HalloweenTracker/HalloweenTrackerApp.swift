//
//  HalloweenTrackerApp.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import SwiftUI
import SwiftData
import FirebaseCore

@main
struct HalloweenTrackerApp: App {
    @StateObject private var auth = AuthManager()
    init(){
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environmentObject(auth)
        }
    }
}
