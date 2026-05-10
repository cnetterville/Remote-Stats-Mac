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
                    LabeledContent("Name") {
                        TextField("Optional", text: $name)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    LabeledContent("Host / IP") {
                        TextField("192.168.1.1", text: $host)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Port") {
                        TextField("", text: $port)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                    }
                    LabeledContent("UPS Name") {
                        TextField("ups", text: $upsName)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                } header: {
                    Text("NUT Server")
                } footer: {
                    Text("The UPS name is the identifier configured in NUT (e.g. \"ups\", \"eaton\").")
                }

                Section("Authentication (optional)") {
                    LabeledContent("Username") {
                        TextField("", text: $username)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    }
                    LabeledContent("Password") {
                        SecureField("", text: $password)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 550, minHeight: 350)
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
