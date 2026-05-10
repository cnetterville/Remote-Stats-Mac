//
//  UPSListView.swift
//  Remote Stats Mac
//

import SwiftUI

// MARK: - UPSStatusFlag view helpers

extension UPSStatusFlag {
    var displayName: String {
        switch self {
        case .onLine:         return "Online"
        case .onBattery:      return "On Battery"
        case .lowBattery:     return "Low Battery"
        case .highBattery:    return "High Battery"
        case .replaceBattery: return "Replace Battery"
        case .charging:       return "Charging"
        case .discharging:    return "Discharging"
        case .bypass:         return "Bypass"
        case .calibrating:    return "Calibrating"
        case .offline:        return "Offline"
        case .overloaded:     return "Overloaded"
        case .trimming:       return "Trimming"
        case .boosting:       return "Boosting"
        case .forcedShutdown: return "Forced Shutdown"
        }
    }

    var color: Color {
        switch self {
        case .onLine, .charging:                           return .green
        case .onBattery, .discharging:                     return .orange
        case .lowBattery, .overloaded, .forcedShutdown,
             .replaceBattery:                              return .red
        case .bypass, .calibrating, .trimming, .boosting: return .yellow
        case .offline:                                     return .gray
        case .highBattery:                                 return .blue
        }
    }

    var icon: String {
        switch self {
        case .onLine:         return "bolt.fill"
        case .onBattery:      return "battery.50percent"
        case .lowBattery:     return "battery.25percent"
        case .charging:       return "battery.100percent.bolt"
        case .discharging:    return "battery.75percent"
        case .replaceBattery: return "battery.slash"
        case .overloaded:     return "exclamationmark.triangle.fill"
        case .bypass:         return "arrow.triangle.2.circlepath"
        case .offline:        return "poweroff"
        case .forcedShutdown: return "xmark.circle.fill"
        default:              return "questionmark.circle"
        }
    }
}

// MARK: -

struct UPSListView: View {
    @Environment(NUTStore.self) private var store
    @State private var showAdd = false
    @State private var editing: NUTConfig? = nil
    @AppStorage("refreshInterval") private var refreshInterval = 0

    var body: some View {
        NavigationStack {
            Group {
                if store.configs.isEmpty {
                    emptyState
                } else {
                    upsList
                }
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.shield.fill")
                            .foregroundStyle(.orange)
                        Text("UPS")
                    }
                    .font(.title3.weight(.semibold))
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showAdd) {
                AddUPSView { config in
                    store.add(config)
                    checkStatus(for: config)
                }
            }
            .sheet(item: $editing) { config in
                AddUPSView(existingConfig: config) { updated in
                    store.update(updated)
                    checkStatus(for: updated)
                }
            }
            .task(id: refreshInterval) {
                await refreshAllStatuses()
                guard refreshInterval > 0 else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(refreshInterval))
                    guard !Task.isCancelled else { break }
                    await refreshAllStatuses()
                }
            }
            .refreshable { await refreshAllStatuses(force: true) }
        }
    }

    // MARK: - List

    private var upsList: some View {
        List {
            ForEach(store.configs) { config in
                NavigationLink(destination: UPSDetailView(config: config)) {
                    UPSRow(config: config, status: store.statuses[config.id])
                }
                .contextMenu {
                    Button { editing = config } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        if let idx = store.configs.firstIndex(where: { $0.id == config.id }) {
                            store.delete(at: IndexSet(integer: idx))
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onMove { store.move(fromOffsets: $0, toOffset: $1) }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.slash.fill")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No UPS Devices")
                .font(.title2.bold())
            Text("Tap + to add a NUT-monitored UPS.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAdd = true
            } label: {
                Label("Add UPS", systemImage: "plus").font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Status Checking

    private func refreshAllStatuses(force: Bool = false) async {
        for config in store.configs where force || store.statuses[config.id] == nil {
            store.statuses[config.id] = UPSRowStatus(isChecking: true)
        }
        await withTaskGroup(of: (UUID, UPSRowStatus).self) { group in
            for config in store.configs {
                group.addTask {
                    let status = await NUTService.checkStatus(for: config)
                    return (config.id, status)
                }
            }
            for await (id, status) in group {
                store.statuses[id] = status
            }
        }
    }

    private func checkStatus(for config: NUTConfig) {
        store.statuses[config.id] = UPSRowStatus(isChecking: true)
        Task {
            store.statuses[config.id] = await NUTService.checkStatus(for: config)
        }
    }
}

// MARK: - UPS Row

struct UPSRow: View {
    let config: NUTConfig
    let status: UPSRowStatus?

    var body: some View {
        HStack(spacing: 12) {
            statusIcon

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(config.name)
                        .font(.title3.weight(.semibold))
                    Spacer()
                    trailingInfo
                }
                Text("\(config.host):\(String(config.port)) · \(config.upsName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: Icon

    @ViewBuilder
    private var statusIcon: some View {
        if let s = status, s.isChecking {
            ProgressView()
                .frame(width: 28, height: 28)
        } else if let flag = rowPrimaryFlag {
            Image(systemName: flag.icon)
                .font(.title2)
                .foregroundStyle(flag.color)
                .frame(width: 28)
        } else {
            Image(systemName: "questionmark.circle")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
        }
    }

    private var rowPrimaryFlag: UPSStatusFlag? {
        guard let s = status, !s.isChecking else { return nil }
        return UPSStats.primaryFlag(from: s.rawStatus)
    }

    // MARK: Trailing

    @ViewBuilder
    private var trailingInfo: some View {
        if let status {
            if status.isChecking {
                ProgressView().scaleEffect(0.75)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if status.error != nil {
                        Text("Unreachable")
                            .font(.callout)
                            .foregroundStyle(.red)
                    } else {
                        let flag = UPSStats.primaryFlag(from: status.rawStatus)
                        Text(flag?.displayName ?? "Unknown")
                            .font(.callout)
                            .foregroundStyle(flag?.color ?? .gray)
                        HStack(spacing: 8) {
                            if let charge = status.batteryCharge {
                                Text("\(Int(charge))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if let runtime = status.formattedRuntime {
                                Image(systemName: "clock")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                Text(runtime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let checked = status.lastChecked {
                        Text(checked, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
