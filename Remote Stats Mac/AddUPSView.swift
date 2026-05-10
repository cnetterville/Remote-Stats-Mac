//
//  AddUPSView.swift
//  Remote Stats Mac
//

import SwiftUI

struct AddUPSView: View {
    var existingConfig: NUTConfig? = nil
    let onSave: (NUTConfig) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = "3493"
    @State private var upsName = "ups"
    @State private var username = ""
    @State private var password = ""

    @Environment(\.dismiss) private var dismiss

    private var saveDisabled: Bool { host.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section("Display") {
                    TextField("Name (optional)", text: $name)
                        .autocorrectionDisabled()
                }

                Section {
                    TextField("Host / IP", text: $host)
                        .autocorrectionDisabled()
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("3493", text: $port)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                    }
                    TextField("UPS name", text: $upsName)
                        .autocorrectionDisabled()
                } header: {
                    Text("NUT Server")
                } footer: {
                    Text("The UPS name is the identifier configured in NUT (e.g. \"ups\", \"eaton\").")
                }

                Section("Authentication (optional)") {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                }
            }
            .navigationTitle(existingConfig == nil ? "Add UPS" : "Edit UPS")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveAndDismiss() }
                        .disabled(saveDisabled)
                }
            }
            .onAppear {
                guard let c = existingConfig else { return }
                name     = c.name
                host     = c.host
                port     = "\(c.port)"
                upsName  = c.upsName
                username = c.username
                password = c.password
            }
        }
    }

    private func saveAndDismiss() {
        var config = existingConfig ?? NUTConfig(name: "", host: "", upsName: "ups")
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        config.name     = name.trimmingCharacters(in: .whitespaces).isEmpty ? trimmedHost : name.trimmingCharacters(in: .whitespaces)
        config.host     = trimmedHost
        config.port     = max(1, Int(port) ?? 3493)
        config.upsName  = upsName.trimmingCharacters(in: .whitespaces).isEmpty ? "ups" : upsName.trimmingCharacters(in: .whitespaces)
        config.username = username
        config.password = password
        onSave(config)
        dismiss()
    }
}
