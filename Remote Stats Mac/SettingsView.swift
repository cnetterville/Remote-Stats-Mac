//
//  SettingsView.swift
//  Remote Stats Mac
//

import SwiftUI

enum SyncSettings {
    private static let key = "iCloudSyncEnabled"

    static var iCloudEnabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

struct SettingsView: View {
    @Environment(ServerStore.self) private var serverStore
    @Environment(NUTStore.self) private var nutStore
    @State private var iCloudSync = SyncSettings.iCloudEnabled
    @AppStorage("useFahrenheit") private var useFahrenheit = false
    @AppStorage("refreshInterval") private var refreshInterval = 0

    var body: some View {
        Form {
            Section {
                Toggle("iCloud Sync", isOn: $iCloudSync)
                    .onChange(of: iCloudSync) { _, newValue in
                        SyncSettings.iCloudEnabled = newValue
                        if newValue {
                            serverStore.enableiCloudSync()
                            nutStore.enableiCloudSync()
                        } else {
                            serverStore.disableiCloudSync()
                            nutStore.disableiCloudSync()
                        }
                    }
            } footer: {
                Text("Sync server and UPS configurations across your devices via iCloud. Passwords are stored in iCloud Keychain.")
            }

            Section("Display") {
                Picker("Temperature", selection: $useFahrenheit) {
                    Text("Celsius").tag(false)
                    Text("Fahrenheit").tag(true)
                }
            }

            Section {
                Picker("Auto-Refresh", selection: $refreshInterval) {
                    Text("Manual Only").tag(0)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                }
            } footer: {
                Text("How often the server and UPS lists automatically refresh.")
            }

            Section("About") {
                HStack {
                    Text("Version")
                    Spacer()
                    Text("\(appVersion) (\(buildNumber))")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "–"
    }
}
