//
//  RegisterView.swift
//  HalloweenTracker
//
//  Created by Aidan Hong on 10/16/25.
//

import SwiftUI

struct RegisterView: View {
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""

    @State private var isSubmitting = false
    @State private var alertMessage: String?
    @State private var showAlert = false

    /// Optional callback so the parent can react (e.g., log the user in) after successful registration.
    var onRegistered: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Personal Information")) {
                    TextField("Name", text: $name)
                        .textContentType(.name)
                        .autocorrectionDisabled(true)

                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .textContentType(.emailAddress)

                    SecureField("Password", text: $password)
                        .textContentType(.newPassword)

                    SecureField("Confirm Password", text: $confirmPassword)
                        .textContentType(.newPassword)
                }

                Section {
                    Button {
                        Task { await registerUser() }
                    } label: {
                        if isSubmitting {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                        } else {
                            Text("Sign Up")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    .disabled(!isFormValid || isSubmitting)
                }
            }
            .navigationTitle("Sign Up")
            .alert("Sign Up", isPresented: $showAlert, actions: {
                Button("OK", role: .cancel) { }
            }, message: {
                Text(alertMessage ?? "")
            })
        }
    }

    private var isFormValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        isValidEmail(email) &&
        !password.isEmpty &&
        password == confirmPassword
    }

    private func isValidEmail(_ email: String) -> Bool {
        // Simple, pragmatic email check
        email.contains("@") && email.contains(".")
    }

    @MainActor
    private func registerUser() async {
        guard isFormValid else {
            alertMessage = validationMessage()
            showAlert = true
            return
        }

        isSubmitting = true
        defer { isSubmitting = false }

        let user = User(name: name, email: email)

        // createUserAuth is assumed to be async and returns an optional UID (String?)
        let uid = await createUserAuth(user: user, password: password)

        guard let uid else {
            alertMessage = "Could not create your account. Please try again."
            showAlert = true
            return
        }

        do {
            // postUser is assumed to be async throwing
            let success = try await postUser(uid: uid, user: user)
            
            
            // Let parent decide what to do (e.g., auth.login(uid:))
            onRegistered?(uid)

            alertMessage = "Account created successfully!"
            showAlert = true
        } catch {
            alertMessage = "We created your account but couldn’t save your profile: \(error.localizedDescription)"
            showAlert = true
        }
    }

    private func validationMessage() -> String {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Please enter your name." }
        if !isValidEmail(email) { return "Please enter a valid email address." }
        if password.isEmpty { return "Please enter a password." }
        if password != confirmPassword { return "Passwords do not match." }
        return "Please check your inputs."
    }
}

#Preview {
    RegisterView()
}

