//
//  Firestore.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import Foundation
import FirebaseFirestore


//------------- GET FUNCTIONS --------------------//

func getUser(uid: String) async throws -> User? {
    let db = Firestore.firestore()
    let docRef = db.collection("users").document(uid)
    
    let snapshot = try await docRef.getDocument()
    
    if snapshot.exists {
        let userData = try snapshot.data(as: User.self)
        return userData
    } else {
        print("No such document")
        return nil
    }
}



//-------------- POST FUNCTIONS --------------------//

func postUser(uid: String, user: User) throws -> User? {
    let db = Firestore.firestore()
    
    let docRef = db.collection("users").document(uid)
    do {
        try docRef.setData(from: user)
        print("User data saved to Firestore successfully")
        return user
    } catch {
        print("Error saving user data to Firestore: \(error.localizedDescription)")
        return nil
    }
}




//---------------- PUT FUNCTIONS --------------------//

func editUser(uid: String, user: User) throws -> Bool {
    let db = Firestore.firestore()
    
    let docRef = db.collection("users").document(uid)
    do {
        try docRef.setData(from: user, merge: true)
        print("User data updated successfully w/ \(user)")
        return true
    } catch {
        print("Error updating user data: \(error.localizedDescription)")
        return false
    }
}


//---------------- DELETE FUNCTIONS --------------------//

func deleteUser(uid: String) async throws -> Bool {
    let db = Firestore.firestore()
    
    let docRef = db.collection("users").document(uid)
    do {
        try await docRef.delete()
        print("User data deleted successfully")
        return true
    } catch {
        print("Error deleting user data: \(error.localizedDescription)")
        return false
    }
}


// ------------------ OTHER FUNCTIONS --------------------//

func getFullDay (current: Date) -> (Date, Date) {
    let calendar = Calendar.current
    
    let startOfDay = calendar.startOfDay(for: current)
    let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay)
    return (startOfDay, endOfDay!)
}
