//
//  AuthUser.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import SwiftUI
import FirebaseCore
import FirebaseFirestore
import FirebaseAuth

// Creates a user and Signs them into Firebase Auth
func createUserAuth(user: User, password: String) async -> String? {
    do {
        let authResult = try await Auth.auth().createUser(withEmail: user.email, password: password)
        let authRes = authResult.user
        print("User created with UID: \(authRes.uid)")
        return authRes.uid
    } catch {
        print("Error creating user: \(error.localizedDescription)")
        return nil
    }
}

// Signs in User to Firebase Auth
func signInUser(email: String, password: String) async -> String? {
    do {
        let authResult = try await Auth.auth().signIn(withEmail: email, password: password)
        let user = authResult.user
        print("User signed in with the UID: \( user.uid)")
        return user.uid
    } catch {
        print("Error signing in: \(error.localizedDescription)")
        return nil
    }
}
