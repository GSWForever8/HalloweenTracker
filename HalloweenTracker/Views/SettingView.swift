//
//  SettingView.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import SwiftUI

struct SettingsView:View{
    @EnvironmentObject var auth:AuthManager
    @State private var showChangeScreen = false
    @State private var changeType = ""
    
    var body: some View{
        VStack {
            HStack {
                Text("Settings")
                    .font(.title)
                Spacer()
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 24)
            List{
                Section("Account Settings"){
                    Button("Delete Data") {deleteUserClick()}
                }
                Section {
                    Button(action: logoutUser) {
                        Text("Log Out")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }
    
    func deleteUserClick(){
        Task {
            do {
                let res = try await deleteUser(uid: auth.userID)
                if res {
                    auth.logout()
                } else {
                    print("Failed to delete user")
                }
            } catch {
                print("Error deleting user: \(error)")
            }
        }
    }
    
    func logoutUser(){
        auth.logout()
    }
}
#Preview {
    SettingsView()
}
