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
import Foundation

// Creates a user and Signs them into Firebase Auth
func createUserAuth(user: User, password: String) async -> String? {
    do {
        let authResult = try await Auth.auth().createUser(withEmail: user.email, password: password)
        let authRes = authResult.user
        print("User created with UID: \(authRes.uid)")
        if let url = URL(string: "http://192.168.86.26:3000/link") { // your Flask server address
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                    let body = ["uid": authRes.uid]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (_, response) = try await URLSession.shared.data(for: request)
                    if let httpResponse = response as? HTTPURLResponse {
                        print("Flask responded with status code: \(httpResponse.statusCode)")
                    }
                }
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
