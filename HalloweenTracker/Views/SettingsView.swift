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
    
    func logoutUser(){
        auth.logout()
    }
}
#Preview {
    SettingsView()
}
