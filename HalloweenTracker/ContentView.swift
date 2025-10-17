//
//  ContentView.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import SwiftUI
import SwiftData

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var auth:AuthManager
    var body: some View {
        if(auth.isUserAuthenticated){
            TabView{
                Tab("Profile",systemImage:"person.fill"){
                    ProfileView()
                }
            }
        } else {
            LoginView()
        }
    }
}

#Preview {
    ContentView().environmentObject(AuthManager())
}
