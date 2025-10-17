//
//  LoginView.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import SwiftUI

struct LoginView: View {
    @State private var email=""
    @State private var password=""
    @EnvironmentObject var auth:AuthManager
    
    var body: some View {
        NavigationView{
            VStack{
                Spacer()
                Text("Halloween Tracker").bold().font(.system(size: 36).weight(.heavy))
                Spacer()
                VStack{
                    Spacer()
                    TextField("Email",text:$email).frame(width:200, height: 35)
                        .multilineTextAlignment(.center).border(Color.black, width:1)
                        .cornerRadius(1)
                    Spacer()
                    SecureField("Password",text:$password).frame(width:200, height: 35)
                        .multilineTextAlignment(.center).border(Color.black, width:1)
                        .cornerRadius(1)
                    Spacer()
                    HStack{
                        Button(action:{authClick()}){
                            Text("Sign In").foregroundColor(.white)
                        }.frame(width:100,height:40)
                            .border(Color.black, width:10)
                            .cornerRadius(20)
                            .background(Color.black)
                        NavigationLink(destination: RegisterView()){
                            Text("Register").foregroundColor(.white)
                        }.frame(width:100,height:40)
                            .border(Color.black, width:10)
                            .cornerRadius(20)
                            .background(Color.black)
                    }
                    Spacer()
                    Button(action:{print("Pressed")}){
                        Text("Forgot Password?").foregroundColor(.black).underline()
                    }
                    Spacer()
                }
                .frame(width:300,height:275)
                .border(Color.black, width:5)
                .cornerRadius(10)
                Spacer()
            }
            
            }
    }
    func authClick(){
        Task {
            let uid = await signInUser(email: email, password: password)
            
            guard let uid = uid else {
                print("Error signing in")
                return
            }
            auth.login(uid: uid)
        }
    }
}
#Preview {
    LoginView()
}
