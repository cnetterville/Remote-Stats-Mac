//
//  ContentView.swift
//  Remote Stats Mac
//

import SwiftUI

struct ContentView: View {
    @State private var store = ServerStore()
    @State private var nutStore = NUTStore()
    @State private var selection: SidebarItem? = .servers

    enum SidebarItem: String, CaseIterable, Identifiable {
        case servers = "Servers"
        case ups = "UPS"
        case tools = "Tools"
        case settings = "Settings"

        var id: Self { self }

        var icon: String {
            switch self {
            case .servers: return "server.rack"
            case .ups: return "bolt.fill"
            case .tools: return "wrench.and.screwdriver"
            case .settings: return "gear"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.icon)
            }
            .navigationTitle("Remote Stats")
        } detail: {
            switch selection {
            case .servers:
                ServerListView()
                    .environment(store)
            case .ups:
                UPSListView()
                    .environment(nutStore)
            case .tools:
                ToolsView()
                    .environment(store)
            case .settings:
                SettingsView()
                    .environment(store)
                    .environment(nutStore)
            case nil:
                Text("Select an item from the sidebar")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    ContentView()
}
