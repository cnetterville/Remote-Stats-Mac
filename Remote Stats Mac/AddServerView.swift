//
//  AddServerView.swift
//  Remote Stats Mac
//

import SwiftUI
import UniformTypeIdentifiers

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss

    var existingServer: ServerConfig? = nil
    var existingTags: [String] = []
    var onSave: (ServerConfig) -> Void

    @State private var name = ""
    @State private var host = ""
    @State private var port = "22"
    @State private var timeout = "30"
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var authMethod: AuthMethod = .password
    @State private var privateKey = ""
    @State private var showingKeyFilePicker = false
    @State private var tag = ""
    @State private var platform: ServerPlatform = .unix

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !host.trimmingCharacters(in: .whitespaces).isEmpty &&
        !username.trimmingCharacters(in: .whitespaces).isEmpty &&
        (authMethod == .password ? !password.isEmpty : !privateKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    LabeledContent {
                        TextField("My Production Server", text: $name)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Name")
                    }

                    LabeledContent {
                        TextField("192.168.1.1 or hostname", text: $host)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    } label: {
                        Text("Host / IP")
                    }

                    LabeledContent {
                        TextField("22", text: $port)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Port")
                    }

                    LabeledContent {
                        TextField("30", text: $timeout)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Timeout (s)")
                    }

                    Picker("Platform", selection: $platform) {
                        ForEach(ServerPlatform.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    if platform == .windows {
                        Text("Requires PowerShell as the default OpenSSH shell.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Group") {
                    LabeledContent {
                        TextField("e.g. Production", text: $tag)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    } label: {
                        Text("Tag")
                    }
                    if !existingTags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(existingTags, id: \.self) { t in
                                    Button(t) { tag = t }
                                        .buttonStyle(.bordered)
                                        .tint(tag == t ? .blue : .secondary)
                                        .controlSize(.small)
                                }
                            }
                        }
                    }
                }

                Section("Authentication") {
                    LabeledContent {
                        TextField("root", text: $username)
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                    } label: {
                        Text("Username")
                    }

                    Picker("Method", selection: $authMethod) {
                        ForEach(AuthMethod.allCases, id: \.self) { method in
                            Text(method.displayName).tag(method)
                        }
                    }

                    if authMethod == .password {
                        HStack {
                            Text("Password")
                            Spacer()
                            Group {
                                if showPassword {
                                    TextField("••••••••", text: $password)
                                } else {
                                    SecureField("••••••••", text: $password)
                                }
                            }
                            .multilineTextAlignment(.trailing)
                            .autocorrectionDisabled()
                            .frame(maxWidth: 200)

                            Button {
                                showPassword.toggle()
                            } label: {
                                Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Private Key")
                                    .font(.subheadline)
                                Spacer()
                                Button("Import") {
                                    showingKeyFilePicker = true
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Button("Paste") {
                                    if let clip = NSPasteboard.general.string(forType: .string) {
                                        privateKey = clip
                                    }
                                }
                                .font(.caption)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            TextEditor(text: $privateKey)
                                .font(.system(.caption2, design: .monospaced))
                                .frame(minHeight: 120)
                                .autocorrectionDisabled()
                        }
                        .fileImporter(isPresented: $showingKeyFilePicker, allowedContentTypes: [.data, .text, .plainText]) { result in
                            if case .success(let url) = result {
                                if url.startAccessingSecurityScopedResource() {
                                    defer { url.stopAccessingSecurityScopedResource() }
                                    if let data = try? Data(contentsOf: url),
                                       let contents = String(data: data, encoding: .utf8) {
                                        privateKey = contents
                                    }
                                }
                            }
                        }
                        Text("Import or paste your PEM private key (Ed25519, RSA, or ECDSA). Passphrase-protected keys are not supported.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("Credentials are stored securely in the device Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(existingServer == nil ? "Add Server" : "Edit Server")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var config = existingServer ?? ServerConfig(
                            name: name, host: host, port: Int(port) ?? 22,
                            username: username, password: password
                        )
                        config.name = name
                        config.host = host.trimmingCharacters(in: .whitespaces)
                        config.port = Int(port) ?? 22
                        config.timeout = max(5, Int(timeout) ?? 30)
                        config.username = username.trimmingCharacters(in: .whitespaces)
                        config.authMethod = authMethod
                        config.password = authMethod == .password ? password : ""
                        config.privateKey = authMethod == .privateKey ? privateKey : ""
                        config.tag = tag.trimmingCharacters(in: .whitespaces)
                        config.platform = platform
                        onSave(config)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
            .onAppear {
                if let s = existingServer {
                    name = s.name
                    host = s.host
                    port = "\(s.port)"
                    timeout = "\(s.timeout)"
                    username = s.username
                    authMethod = s.authMethod
                    password = s.password
                    privateKey = s.privateKey
                    tag = s.tag
                    platform = s.platform
                }
            }
        }
    }
}
