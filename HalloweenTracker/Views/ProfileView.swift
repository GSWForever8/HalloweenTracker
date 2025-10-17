//
//  ProfileView.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import SwiftUI
import Charts

struct ProfileView: View{
    @EnvironmentObject var auth:AuthManager
    @State private var addPopover = false
    @State private var settingPopover = false
    @State private var loading = true
    @State private var user: User?
    @State private var errorLoading = false
    
    
    struct ValuePerCategory {
        var category: String
        var value: Int
    }
    
    var body: some View{
        if !loading && !errorLoading {
            VStack{
                ScrollView{
                    HStack{
                        Button(action:{settingPopover.toggle()}){
                            Image(systemName:"gear").font(.title)}.popover(isPresented:$settingPopover,arrowEdge:.top){SettingsView()}
                        Spacer()
                        Button(action: {
                            addPopover.toggle()
                        }) {
                            Image(systemName: "plus")
                                .font(.title)
                        }
                    }
                    .padding(.horizontal, 32)
                    Circle().frame(width: 120, height:120)
                    Text(user!.name).bold().font(.system(size: 36).weight(.heavy))
                    Spacer()
                    Spacer()
                }
            }
        } else if loading {
            Text("Loading...")
                .onAppear {
                    loadData()
                }
        } else {
            Text("Error loading data")
            Button("Retry") {
                loadData()
            }
        }
    }
    
    func loadData() {
        Task {
            do {
                user = try await getUser(uid: auth.userID)
                guard let user = user else {
                    print("User not found")
                    errorLoading = true
                    return
                }
                loading = false
                errorLoading = false
            } catch {
                print("Error loading user data: \(error)")
                errorLoading = true
            }
        }
    }
}
