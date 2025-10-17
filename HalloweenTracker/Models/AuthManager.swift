//
//  AuthManager.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import Foundation
import FirebaseAuth
import Combine

class AuthManager: ObservableObject {
    // Published property to trigger UI updates
    @Published var isUserAuthenticated = false
    @Published var userID: String = ""
    
    init() {
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            self.userID = "preview-user-id"
            self.isUserAuthenticated = true
            return
        }
        // Check if the user is already authenticated
        if let user = Auth.auth().currentUser {
            self.userID = user.uid
            self.isUserAuthenticated = true
        } else {
            self.userID = ""
            self.isUserAuthenticated = false
        }
    }
    
    func login(uid: String) {
        userID = uid
        isUserAuthenticated = true
    }
    
    func logout(){
        do {
            try Auth.auth().signOut()
            print("User signed out successfully.")
        } catch {
            print("Error signing out: \(error.localizedDescription)")
        }
        userID = ""
        isUserAuthenticated = false
    }
}
