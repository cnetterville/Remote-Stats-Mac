//
//  ServerDetailView.swift
//  Remote Stats Mac
//

import SwiftUI

@Observable
@MainActor
class ServerViewModel {
    var stats: ServerStats?
    var isLoading = false
    var errorMessage: String?
    var isLiveUpdating = false
    var rxRate: Int64 = 0
    var txRate: Int64 = 0
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []

    let server: ServerConfig
    var store: ServerStore?

    private static let maxHistoryPoints = 30
    private var pollingTask: Task<Void, Never>?

    init(server: ServerConfig) {
        self.server = server
    }

    func loadStats(isRefresh: Bool = false) async {
        stopPolling()
        if !isRefresh {
            isLoading = true
            cpuHistory = []
            memoryHistory = []
        }
        errorMessage = nil
        rxRate = 0
        txRate = 0
        do {
            let cachedNet = store?.networkCache[server.id]
            let cachedUpd = store?.updateCache[server.id]
            stats = try await SSHService.fetchStats(for: server, cachedNetwork: cachedNet, cachedUpdate: cachedUpd)
            if let stats, !stats.externalIP.isEmpty {
                store?.networkCache[server.id] = CachedNetworkInfo(
                    externalIP: stats.externalIP,
                    isp: stats.isp,
                    location: stats.location,
                    lastFetched: Date()
                )
                store?.saveNetworkCache()
            }
            if let updates = stats?.pendingUpdates {
                store?.updateCache[server.id] = CachedUpdateInfo(count: updates, lastFetched: Date())
                store?.saveUpdateCache()
            }
            recordHistory()
            startPolling()
        } catch is CancellationError {
            // Ignore — task was cancelled (e.g. view disappeared)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    var isCheckingUpdates = false
    var isCheckingDockerUpdates = false
    var dockerActionInProgress: Set<String> = []
    var proxmoxActionInProgress: Set<String> = []

    func checkDockerUpdates() async {
        guard let containers = stats?.dockerContainers, !containers.isEmpty else { return }
        isCheckingDockerUpdates = true
        let updatedIDs = await SSHService.checkDockerUpdates(containers: containers, config: server)
        if let current = stats?.dockerContainers {
            for i in current.indices {
                stats?.dockerContainers[i].updateAvailable = updatedIDs.contains(current[i].id)
            }
        }
        isCheckingDockerUpdates = false
    }

    func dockerUpdate(container: DockerContainer) async {
        dockerActionInProgress.insert(container.id)
        do {
            try await SSHService.dockerComposeRecreate(
                project: container.composeProject,
                service: container.composeService,
                config: server
            )
            try? await Task.sleep(for: .seconds(2))
            let updated = try await SSHService.fetchDockerContainers(config: server)
            stats?.dockerContainers = updated
        } catch {
            errorMessage = "Docker update failed: \(error.localizedDescription)"
        }
        dockerActionInProgress.remove(container.id)
    }

    func dockerAction(_ action: String, container: DockerContainer) async {
        dockerActionInProgress.insert(container.id)
        do {
            try await SSHService.dockerAction(action, container: container.name, config: server)
            try? await Task.sleep(for: .seconds(1))
            let updated = try await SSHService.fetchDockerContainers(config: server)
            stats?.dockerContainers = updated
        } catch {
            errorMessage = "Docker \(action) failed: \(error.localizedDescription)"
        }
        dockerActionInProgress.remove(container.id)
    }

    func proxmoxAction(_ action: String, guest: ProxmoxGuest) async {
        proxmoxActionInProgress.insert(guest.id)
        do {
            try await SSHService.proxmoxAction(action, guest: guest, config: server)
            try? await Task.sleep(for: .seconds(2))
            let updated = try await SSHService.fetchProxmoxGuests(config: server)
            stats?.proxmoxGuests = updated
        } catch {
            errorMessage = "Proxmox \(action) failed: \(error.localizedDescription)"
        }
        proxmoxActionInProgress.remove(guest.id)
    }

    func checkForUpdates() async {
        isCheckingUpdates = true
        do {
            let count = try await SSHService.checkForUpdates(config: server)
            stats?.pendingUpdates = count
            if let count {
                store?.updateCache[server.id] = CachedUpdateInfo(count: count, lastFetched: Date())
                store?.saveUpdateCache()
            }
        } catch { }
        isCheckingUpdates = false
    }

    func toggleLive() {
        if pollingTask != nil {
            stopPolling()
        } else if stats != nil {
            startPolling()
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isLiveUpdating = false
    }

    private func startPolling() {
        pollingTask = Task {
            do {
                let client = try await SSHService.openConnection(for: server)
                defer { SSHService.closeConnection(client) }

                var prevRx = stats?.rxBytes ?? 0
                var prevTx = stats?.txBytes ?? 0
                var prevTime = Date()

                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { break }

                    let live = try await SSHService.fetchLiveStats(on: client, platform: server.platform)

                    let now = Date()
                    let elapsed = now.timeIntervalSince(prevTime)
                    if elapsed > 0 && live.rxBytes >= prevRx {
                        rxRate = Int64(Double(live.rxBytes - prevRx) / elapsed)
                        txRate = Int64(Double(live.txBytes - prevTx) / elapsed)
                    }
                    prevRx = live.rxBytes
                    prevTx = live.txBytes
                    prevTime = now

                    stats?.uptime = live.uptime
                    stats?.memory = live.memory
                    stats?.load = live.load
                    stats?.temperatureCelsius = live.temperatureCelsius
                    stats?.processes = live.processes
                    stats?.memoryProcesses = live.memoryProcesses
                    stats?.rxBytes = live.rxBytes
                    stats?.txBytes = live.txBytes

                    recordHistory()
                    isLiveUpdating = true
                }
            } catch is CancellationError {
                // View disappeared
            } catch {
                // Connection lost
            }
            isLiveUpdating = false
        }
    }

    private func recordHistory() {
        guard let stats else { return }
        if stats.cpuCores > 0, let load1 = Double(stats.load.oneMin) {
            let util = min(load1 / Double(stats.cpuCores), 1.0)
            cpuHistory.append(util)
            if cpuHistory.count > Self.maxHistoryPoints { cpuHistory.removeFirst() }
        }
        let mem = stats.memory.usedPercent
        if mem > 0 {
            memoryHistory.append(mem)
            if memoryHistory.count > Self.maxHistoryPoints { memoryHistory.removeFirst() }
        }
    }
}

struct ServerDetailView: View {
    let server: ServerConfig
    @Environment(ServerStore.self) private var store
    @State private var viewModel: ServerViewModel

    init(server: ServerConfig) {
        self.server = server
        self._viewModel = State(initialValue: ServerViewModel(server: server))
    }

    var body: some View {
        ScrollView {
            if viewModel.isLoading {
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.4)
                    Text("Connecting via SSH…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 120)

            } else if let error = viewModel.errorMessage {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Connection Failed")
                        .font(.title2.bold())
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Try Again") {
                        Task { await viewModel.loadStats() }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 100)

            } else if let stats = viewModel.stats {
                StatsContentView(
                    stats: stats,
                    server: server,
                    isLiveUpdating: viewModel.isLiveUpdating,
                    rxRate: viewModel.rxRate,
                    txRate: viewModel.txRate,
                    cpuHistory: viewModel.cpuHistory,
                    memoryHistory: viewModel.memoryHistory,
                    dockerActionInProgress: viewModel.dockerActionInProgress,
                    onDockerAction: { action, container in
                        Task { await viewModel.dockerAction(action, container: container) }
                    },
                    isCheckingDockerUpdates: viewModel.isCheckingDockerUpdates,
                    onCheckDockerUpdates: {
                        Task { await viewModel.checkDockerUpdates() }
                    },
                    onDockerUpdate: { container in
                        Task { await viewModel.dockerUpdate(container: container) }
                    },
                    proxmoxActionInProgress: viewModel.proxmoxActionInProgress,
                    onProxmoxAction: { action, guest in
                        Task { await viewModel.proxmoxAction(action, guest: guest) }
                    },
                    isCheckingUpdates: viewModel.isCheckingUpdates,
                    onCheckUpdates: {
                        Task { await viewModel.checkForUpdates() }
                    }
                )
            }
        }
        .navigationTitle(server.name)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await viewModel.loadStats() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)

                Menu {
                    Button {
                        viewModel.toggleLive()
                    } label: {
                        Label(
                            viewModel.isLiveUpdating ? "Stop Live View" : "Start Live View",
                            systemImage: viewModel.isLiveUpdating ? "waveform.circle.fill" : "waveform.circle"
                        )
                    }
                    .disabled(viewModel.isLoading || viewModel.stats == nil)

                    NavigationLink(destination: ConsoleView(server: server)) {
                        Label("Console", systemImage: "terminal.fill")
                    }

                    if #available(macOS 15.0, *) {
                        NavigationLink(destination: TerminalView(server: server)) {
                            Label("Terminal", systemImage: "chevron.left.forwardslash.chevron.right")
                        }
                    }
                } label: {
                    Image(systemName: viewModel.isLiveUpdating ? "ellipsis.circle.fill" : "ellipsis.circle")
                        .foregroundStyle(viewModel.isLiveUpdating ? .green : .secondary)
                }
            }
        }
        .task {
            viewModel.store = store
            await viewModel.loadStats()
        }
        .onDisappear { viewModel.stopPolling() }
        .refreshable { await viewModel.loadStats(isRefresh: true) }
    }
}

// MARK: - Stats Content

struct StatsContentView: View {
    let stats: ServerStats
    let server: ServerConfig
    var isLiveUpdating: Bool = false
    var rxRate: Int64 = 0
    var txRate: Int64 = 0
    var cpuHistory: [Double] = []
    var memoryHistory: [Double] = []
    var dockerActionInProgress: Set<String> = []
    var onDockerAction: ((String, DockerContainer) -> Void)? = nil
    var isCheckingDockerUpdates: Bool = false
    var onCheckDockerUpdates: (() -> Void)? = nil
    var onDockerUpdate: ((DockerContainer) -> Void)? = nil
    var proxmoxActionInProgress: Set<String> = []
    var onProxmoxAction: ((String, ProxmoxGuest) -> Void)? = nil
    var isCheckingUpdates: Bool = false
    var onCheckUpdates: (() -> Void)? = nil
    @AppStorage("useFahrenheit") private var useFahrenheit = false
    @State private var showUpdateConfirm = false
    @State private var navigateToUpdateTerminal = false
    @State private var pendingUpdateCommand: String?
    @State private var navigateToConsole = false
    @State private var pendingConsoleCommand: String?

    var body: some View {
        VStack(spacing: 16) {
            // Host info strip
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(.blue)
                Text("\(server.username)@\(server.host):\(server.port)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isLiveUpdating {
                    Text("Live")
                        .font(.caption2.bold())
                        .foregroundStyle(.green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.15))
                        .clipShape(Capsule())
                }
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text("Online")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            .padding(.horizontal, 4)

            // OS
            StatCard(title: "Operating System", icon: "desktopcomputer", color: .blue) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(stats.osVersion)
                        .font(.body)
                    if let updates = stats.pendingUpdates {
                        HStack(spacing: 4) {
                            Image(systemName: updates > 0 ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                                .font(.caption)
                            Text(updates > 0 ? "\(updates) update\(updates == 1 ? "" : "s") available" : "Up to date")
                                .font(.caption)
                            Spacer()
                            Button {
                                onCheckUpdates?()
                            } label: {
                                Group {
                                    if isCheckingUpdates {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                }
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isCheckingUpdates)
                            if updates > 0, let cmd = updateCommand(for: server) {
                                if #available(macOS 15.0, *) {
                                    Button {
                                        showUpdateConfirm = true
                                    } label: {
                                        Label("Apply", systemImage: "arrow.down.circle")
                                            .font(.caption2.bold())
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.orange.opacity(0.12))
                                            .foregroundStyle(.orange)
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .confirmationDialog(
                                        "Apply \(updates) update\(updates == 1 ? "" : "s")?",
                                        isPresented: $showUpdateConfirm,
                                        titleVisibility: .visible
                                    ) {
                                        Button("Open Terminal & Apply") {
                                            pendingUpdateCommand = cmd
                                            navigateToUpdateTerminal = true
                                        }
                                        Button("Cancel", role: .cancel) {}
                                    } message: {
                                        if server.platform == .windows {
                                            Text("This will open a terminal session and install pending Windows updates via the Windows Update service.")
                                        } else {
                                            Text("This will open a terminal session and run:\n\(cmd)")
                                        }
                                    }
                                }
                            }
                        }
                        .foregroundStyle(updates > 0 ? .orange : .green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Network
            if !stats.internalIP.isEmpty || !stats.externalIP.isEmpty {
                StatCard(title: "Network", icon: "network", color: .blue) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !stats.hostname.isEmpty {
                            NetworkRow(label: "Hostname", value: stats.hostname)
                        }
                        if !stats.internalIP.isEmpty {
                            NetworkRow(label: "Internal IP", value: stats.internalIP)
                        }
                        if !stats.externalIP.isEmpty {
                            NetworkRow(label: "External IP", value: stats.externalIP)
                        }
                        if !stats.gateway.isEmpty {
                            NetworkRow(label: "Gateway", value: stats.gateway)
                        }
                        if !stats.networkInterface.isEmpty {
                            let ifaceLabel = [stats.networkInterface, stats.linkSpeed]
                                .filter { !$0.isEmpty }
                                .joined(separator: " · ")
                            NetworkRow(label: "Interface", value: ifaceLabel)
                        }
                        if !stats.macAddress.isEmpty {
                            NetworkRow(label: "MAC", value: stats.macAddress)
                        }
                        if !stats.dnsServers.isEmpty {
                            NetworkRow(label: "DNS", value: stats.dnsServers)
                        }
                        if stats.rxBytes > 0 || stats.txBytes > 0 {
                            NetworkRow(label: "Traffic", value: "↓ \(formatBytes(stats.rxBytes))  ↑ \(formatBytes(stats.txBytes))")
                        }
                        if isLiveUpdating && (rxRate > 0 || txRate > 0) {
                            NetworkRow(label: "Speed", value: "↓ \(formatBytes(rxRate))/s  ↑ \(formatBytes(txRate))/s")
                        }
                        if !stats.isp.isEmpty {
                            NetworkRow(label: "ISP", value: stats.isp)
                        }
                        if !stats.location.isEmpty {
                            NetworkRow(label: "Location", value: stats.location)
                        }
                        if let ms = stats.latencyMs {
                            NetworkRow(label: "Latency", value: String(format: "%.0f ms", ms))
                        }
                    }
                }
            }

            // Uptime + Boot in a row
            HStack(spacing: 16) {
                StatCard(title: "Uptime", icon: "clock.fill", color: .green) {
                    Text(stats.uptime)
                        .font(.headline)
                        .minimumScaleFactor(0.7)
                }
                StatCard(title: "Boot Time", icon: "power", color: .orange) {
                    Text(stats.bootTime)
                        .font(.subheadline)
                        .minimumScaleFactor(0.6)
                        .lineLimit(2)
                }
            }

            // Memory
            StatCard(title: "Memory", icon: "memorychip.fill", color: .purple) {
                VStack(alignment: .leading, spacing: 10) {
                    ProgressView(value: stats.memory.usedPercent)
                        .tint(memoryTint(stats.memory.usedPercent))
                        .animation(.easeOut, value: stats.memory.usedPercent)

                    if !memoryHistory.isEmpty {
                        SparklineView(data: memoryHistory, color: .purple)
                            .frame(height: 40)
                    }

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Used")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(stats.memory.usedFormatted)
                                .font(.subheadline.bold())
                        }
                        Spacer()
                        VStack(alignment: .center, spacing: 2) {
                            Text("Free")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(stats.memory.freeFormatted)
                                .font(.subheadline.bold())
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("Total")
                                .font(.caption2).foregroundStyle(.secondary)
                            Text(stats.memory.totalFormatted)
                                .font(.subheadline.bold())
                        }
                    }
                    Text("\(Int(stats.memory.usedPercent * 100))% utilization")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if stats.memory.hasSwap {
                        Divider()
                        Text("Swap")
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)
                        ProgressView(value: stats.memory.swapPercent)
                            .tint(memoryTint(stats.memory.swapPercent))
                            .animation(.easeOut, value: stats.memory.swapPercent)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Used")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(stats.memory.swapUsedFormatted)
                                    .font(.subheadline.bold())
                            }
                            Spacer()
                            VStack(alignment: .center, spacing: 2) {
                                Text("Free")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(stats.memory.swapFreeFormatted)
                                    .font(.subheadline.bold())
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("Total")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(stats.memory.swapTotalFormatted)
                                    .font(.subheadline.bold())
                            }
                        }
                        Text("\(Int(stats.memory.swapPercent * 100))% swap utilization")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Disks
            if !stats.disks.isEmpty {
                StatCard(title: "Storage", icon: "internaldrive.fill", color: .brown) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(stats.disks) { mount in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(mount.mountPath)
                                    .font(.caption.bold().monospaced())
                                ProgressView(value: mount.usedPercent)
                                    .tint(diskTint(mount.usedPercent))
                                    .animation(.easeOut, value: mount.usedPercent)
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Used")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(mount.usedFormatted)
                                            .font(.subheadline.bold())
                                    }
                                    Spacer()
                                    VStack(alignment: .center, spacing: 2) {
                                        Text("Free")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(mount.freeFormatted)
                                            .font(.subheadline.bold())
                                    }
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("Total")
                                            .font(.caption2).foregroundStyle(.secondary)
                                        Text(mount.totalFormatted)
                                            .font(.subheadline.bold())
                                    }
                                }
                                Text("\(Int(mount.usedPercent * 100))% utilization")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if mount.id != stats.disks.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            // CPU
            StatCard(title: "CPU", icon: "cpu.fill", color: .indigo) {
                VStack(alignment: .leading, spacing: 10) {
                    if !stats.machineModel.isEmpty {
                        Text(stats.machineModel)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if stats.cpuModel != "--" {
                        Text(stats.cpuModel)
                            .font(.subheadline)
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                    }
                    if stats.cpuCores > 0 {
                        if !stats.cpuCoreDetails.isEmpty {
                            Text("\(stats.cpuCores) cores (\(stats.cpuCoreDetails))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("\(stats.cpuCores) logical cores")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        LoadPill(label: "1 min",  value: stats.load.oneMin)
                        Spacer()
                        LoadPill(label: "5 min",  value: stats.load.fiveMin)
                        Spacer()
                        LoadPill(label: "15 min", value: stats.load.fifteenMin)
                    }
                    .padding(.top, 2)
                    if stats.cpuCores > 0, let load1 = Double(stats.load.oneMin) {
                        let utilization = min(load1 / Double(stats.cpuCores), 1.0)
                        VStack(alignment: .leading, spacing: 4) {
                            ProgressView(value: utilization)
                                .tint(cpuTint(utilization))
                                .animation(.easeOut, value: utilization)
                            if !cpuHistory.isEmpty {
                                SparklineView(data: cpuHistory, color: .indigo)
                                    .frame(height: 40)
                            }
                            Text("\(Int(utilization * 100))% utilization")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            // Top CPU Processes
            if !stats.processes.isEmpty {
                StatCard(title: "Top CPU Processes", icon: "cpu", color: .cyan) {
                    ProcessTable(entries: stats.processes, highlightColumn: .cpu)
                }
            }

            // Top Memory Processes
            if !stats.memoryProcesses.isEmpty {
                StatCard(title: "Top Memory Processes", icon: "memorychip", color: .purple) {
                    ProcessTable(entries: stats.memoryProcesses, highlightColumn: .mem)
                }
            }

            // Docker Containers — only shown when Docker is installed
            if !stats.dockerContainers.isEmpty {
                let running = stats.dockerContainers.filter(\.isRunning).count
                let total = stats.dockerContainers.count
                let updatesAvailable = stats.dockerContainers.filter(\.updateAvailable).count
                StatCard(title: "Docker (\(running)/\(total) running)", icon: "shippingbox.fill", color: .blue) {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            if updatesAvailable > 0 {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                Text("\(updatesAvailable) update\(updatesAvailable == 1 ? "" : "s") available")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button {
                                onCheckDockerUpdates?()
                            } label: {
                                HStack(spacing: 4) {
                                    if isCheckingDockerUpdates {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    Text("Check Updates")
                                }
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.12))
                                .foregroundStyle(.blue)
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isCheckingDockerUpdates)
                        }
                        .padding(.bottom, 8)

                        ForEach(stats.dockerContainers) { container in
                            DockerRow(
                                container: container,
                                isActionInProgress: dockerActionInProgress.contains(container.id),
                                onAction: onDockerAction.map { callback in
                                    { action in callback(action, container) }
                                },
                                onUpdate: (container.updateAvailable && !container.composeProject.isEmpty) ? {
                                    onDockerUpdate?(container)
                                } : nil
                            )
                            if container.id != stats.dockerContainers.last?.id {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }

            // Proxmox VMs & LXCs — only shown on Proxmox hosts
            if !stats.proxmoxGuests.isEmpty {
                let running = stats.proxmoxGuests.filter(\.isRunning).count
                let total = stats.proxmoxGuests.count
                StatCard(title: "Proxmox (\(running)/\(total) running)", icon: "server.rack", color: .orange) {
                    VStack(spacing: 0) {
                        ForEach(stats.proxmoxGuests) { guest in
                            NavigationLink(destination: ProxmoxGuestDetailView(guest: guest, server: server)) {
                                ProxmoxRow(
                                    guest: guest,
                                    isActionInProgress: proxmoxActionInProgress.contains(guest.id),
                                    onAction: onProxmoxAction.map { callback in
                                        { action in callback(action, guest) }
                                    },
                                    onConsole: guest.type == "lxc" ? {
                                        pendingConsoleCommand = "pct enter \(guest.id)"
                                        navigateToConsole = true
                                    } : nil
                                )
                            }
                            .buttonStyle(.plain)
                            if guest.id != stats.proxmoxGuests.last?.id {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }

            // Proxmox Storage — only shown on Proxmox hosts
            if !stats.proxmoxStorage.isEmpty {
                StatCard(title: "Proxmox Storage", icon: "internaldrive", color: .orange) {
                    VStack(spacing: 10) {
                        ForEach(stats.proxmoxStorage) { vol in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(vol.storage)
                                        .font(.subheadline.bold())
                                    Text(vol.type)
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.orange.opacity(0.15))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                    if !vol.node.isEmpty {
                                        Text(vol.node)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Text("\(vol.formattedUsed) / \(vol.formattedTotal)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(Color.orange.opacity(0.15))
                                        RoundedRectangle(cornerRadius: 3)
                                            .fill(vol.usedPercent > 0.9 ? Color.red : vol.usedPercent > 0.7 ? Color.orange : Color.blue)
                                            .frame(width: max(0, geo.size.width * min(vol.usedPercent, 1.0)))
                                    }
                                }
                                .frame(height: 6)
                                HStack {
                                    Text("\(Int(vol.usedPercent * 100))% used")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(vol.formattedFree) free")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if vol.id != stats.proxmoxStorage.last?.id {
                                Divider()
                            }
                        }
                    }
                }
            }

            // CPU Temperature — only shown when a reading is available
            if let celsius = stats.temperatureCelsius {
                StatCard(title: "CPU Temperature", icon: "thermometer.medium", color: .red) {
                    HStack(spacing: 12) {
                        Image(systemName: tempIconName(celsius))
                            .font(.title)
                            .foregroundStyle(tempTint(celsius))
                        Text(formattedTemp(celsius))
                            .font(.title.bold())
                            .foregroundStyle(tempTint(celsius))
                    }
                }
            }

            // Power / Pi Throttle — shown when RAPL/IPMI data or Pi throttle flags are available
            if stats.powerWatts != nil || stats.piThrottleFlags != nil {
                StatCard(title: "Power", icon: "bolt.fill", color: .yellow) {
                    VStack(alignment: .leading, spacing: 10) {
                        if let watts = stats.powerWatts {
                            HStack(spacing: 12) {
                                Image(systemName: "bolt.fill")
                                    .font(.title)
                                    .foregroundStyle(.yellow)
                                Text(String(format: "%.1f W", watts))
                                    .font(.title.bold())
                                    .foregroundStyle(.primary)
                            }
                        }
                        if let flags = stats.piThrottleFlags {
                            throttleStatusView(flags: flags)
                        }
                    }
                }
            }

            // Logins
            StatCard(
                title: "Logins (\(stats.logins.filter(\.isActive).count) active / \(stats.logins.count) total)",
                icon: "person.2.fill",
                color: .teal
            ) {
                if stats.logins.isEmpty {
                    Text("No recent login records")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(stats.logins) { login in
                            LoginRow(login: login)
                            if login.id != stats.logins.last?.id {
                                Divider().padding(.leading, 20)
                            }
                        }
                    }
                }
            }
        }
        .padding()
        .textSelection(.enabled)
        .navigationDestination(isPresented: $navigateToUpdateTerminal) {
            if #available(macOS 15.0, *), let cmd = pendingUpdateCommand {
                TerminalView(server: server, initialCommand: cmd)
            }
        }
        .navigationDestination(isPresented: $navigateToConsole) {
            if #available(macOS 15.0, *), let cmd = pendingConsoleCommand {
                TerminalView(server: server, initialCommand: cmd)
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        guard bytes > 0 else { return "0" }
        let tb = Double(bytes) / 1_099_511_627_776
        if tb >= 1.0 { return String(format: "%.1f TB", tb) }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1.0 { return String(format: "%.1f MB", mb) }
        let kb = Double(bytes) / 1024
        return String(format: "%.0f KB", kb)
    }

    private func diskTint(_ pct: Double) -> Color {
        if pct > 0.9 { return .red }
        if pct > 0.75 { return .orange }
        return .brown
    }

    private func cpuTint(_ pct: Double) -> Color {
        if pct > 0.9 { return .red }
        if pct > 0.7 { return .orange }
        return .indigo
    }

    private func memoryTint(_ pct: Double) -> Color {
        if pct > 0.9 { return .red }
        if pct > 0.7 { return .orange }
        return .green
    }

    private func formattedTemp(_ celsius: Double) -> String {
        useFahrenheit
            ? String(format: "%.1f°F", celsius * 9 / 5 + 32)
            : String(format: "%.1f°C", celsius)
    }

    private func tempTint(_ celsius: Double) -> Color {
        if celsius > 80 { return .red }
        if celsius > 65 { return .orange }
        return .primary
    }

    private func tempIconName(_ celsius: Double) -> String {
        if celsius > 80 { return "thermometer.high" }
        if celsius > 65 { return "thermometer.medium" }
        return "thermometer.low"
    }

    @ViewBuilder
    private func throttleStatusView(flags: UInt32) -> some View {
        let currentFlags: [(bit: Int, label: String, icon: String)] = [
            (0, "Under-voltage", "exclamationmark.bolt.fill"),
            (1, "Frequency capped", "gauge.with.dots.needle.0percent"),
            (2, "Throttled", "flame.fill"),
            (3, "Soft temp limit", "thermometer.high"),
        ]
        let historicalFlags: [(bit: Int, label: String)] = [
            (16, "Under-voltage"),
            (17, "Frequency capped"),
            (18, "Throttled"),
            (19, "Soft temp limit"),
        ]

        if flags == 0 {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("No throttling detected")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                let activeFlags = currentFlags.filter { flags & (1 << $0.bit) != 0 }
                if !activeFlags.isEmpty {
                    Text("Active")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                    ForEach(activeFlags, id: \.bit) { flag in
                        HStack(spacing: 6) {
                            Image(systemName: flag.icon)
                                .foregroundStyle(.red)
                                .frame(width: 16)
                            Text(flag.label)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                let histOnly = historicalFlags.filter { h in
                    flags & (1 << h.bit) != 0 && flags & (1 << (h.bit - 16)) == 0
                }
                if !histOnly.isEmpty {
                    Text("Since last boot")
                        .font(.caption.bold())
                        .foregroundStyle(.orange)
                    ForEach(histOnly, id: \.bit) { flag in
                        HStack(spacing: 6) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.orange)
                                .frame(width: 16)
                            Text(flag.label)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func updateCommand(for server: ServerConfig) -> String? {
        if server.platform == .windows {
            let script = [
                "$ErrorActionPreference='SilentlyContinue'",
                "Write-Host 'Checking for available updates...'",
                "$s=New-Object -ComObject Microsoft.Update.Session",
                "$r=$s.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0')",
                "$n=$r.Updates.Count",
                "if($n -eq 0){Write-Host 'No updates available.';exit}",
                "Write-Host \"$n update(s) to install:\"",
                "foreach($u in $r.Updates){Write-Host \"  - $($u.Title)\"}",
                "Write-Host ''",
                "Write-Host 'Starting installation...'",
                "if(Get-Command UsoClient -ErrorAction SilentlyContinue){",
                "  UsoClient StartInstall",
                "  Write-Host 'Installation initiated via Windows Update service.'",
                "}else{",
                "  wuauclt /detectnow /updatenow",
                "  Write-Host 'Installation initiated via wuauclt.'",
                "}",
                "Write-Host ''",
                "Write-Host 'Updates are installing in the background.'",
                "Write-Host 'A restart may be required when complete.'"
            ].joined(separator: "\n")
            guard let data = script.data(using: .utf16LittleEndian) else { return nil }
            return "powershell -NoProfile -EncodedCommand \(data.base64EncodedString())"
        }
        let isProxmox = !stats.proxmoxGuests.isEmpty
        let sudo = isProxmox ? "" : "sudo "
        let os = stats.osVersion.lowercased()
        if os.contains("ubuntu") || os.contains("debian") || os.contains("raspbian") || os.contains("mint") {
            return "\(sudo)apt-get update && \(sudo)apt-get upgrade -y"
        } else if os.contains("fedora") {
            return "\(sudo)dnf upgrade -y"
        } else if os.contains("centos") || os.contains("red hat") || os.contains("rhel") || os.contains("rocky") || os.contains("alma") {
            return "\(sudo)yum upgrade -y"
        } else if os.contains("arch") || os.contains("manjaro") {
            return "\(sudo)pacman -Syu --noconfirm"
        } else if os.contains("alpine") {
            return "\(sudo)apk update && \(sudo)apk upgrade"
        } else if os.contains("macos") || os.contains("mac os") || os.contains("darwin") {
            return "softwareupdate -ia"
        }
        return "\(sudo)apt-get update && \(sudo)apt-get upgrade -y"
    }
}

// MARK: - Reusable Card

struct StatCard<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(color)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Network Row

struct NetworkRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.subheadline.monospaced())
        }
    }
}

// MARK: - Load Average Pill

struct LoadPill: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Process Table

enum ProcessHighlight { case cpu, mem }

struct ProcessTable: View {
    let entries: [ProcessEntry]
    var highlightColumn: ProcessHighlight = .cpu

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PROCESS")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("CPU")
                    .frame(width: 60, alignment: .trailing)
                Text("MEM")
                    .frame(width: 60, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.bottom, 6)

            ForEach(entries) { entry in
                ProcessRow(entry: entry, highlight: highlightColumn)
                if entry.id != entries.last?.id {
                    Divider().padding(.leading, 0)
                }
            }
        }
    }
}

// MARK: - Process Row

struct ProcessRow: View {
    let entry: ProcessEntry
    var highlight: ProcessHighlight = .cpu

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName)
                    .font(.subheadline.bold())
                    .lineLimit(1)
                Text("\(entry.user) · \(entry.pid)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatPercent(entry.cpu))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(highlight == .cpu ? valueColor(entry.cpu) : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 60, alignment: .trailing)

            Text(formatPercent(entry.mem))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(highlight == .mem ? valueColor(entry.mem) : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private func formatPercent(_ val: Double) -> String {
        if val >= 100 {
            return String(format: "%.0f%%", val)
        }
        return String(format: "%.1f%%", val)
    }

    private func valueColor(_ val: Double) -> Color {
        if val > 50 { return .red }
        if val > 15 { return .orange }
        return .primary
    }
}

// MARK: - Login Row

struct LoginRow: View {
    let login: LoginEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(login.isActive ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(login.user)
                        .font(.subheadline.bold())
                    Text(login.terminal)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
                if login.from != "-" {
                    Text("from \(login.from)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(login.dateString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if login.isActive {
                Text("Active")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Docker Row

struct DockerRow: View {
    let container: DockerContainer
    var isActionInProgress: Bool = false
    var onAction: ((String) -> Void)? = nil
    var onUpdate: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name)
                        .font(.subheadline.bold())
                        .lineLimit(1)
                    Text(container.image)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(container.status)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(container.isRunning ? "Running" : "Stopped")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((container.isRunning ? Color.green : Color.red).opacity(0.15))
                    .foregroundStyle(container.isRunning ? .green : .red)
                    .clipShape(Capsule())
            }

            if onAction != nil || onUpdate != nil {
                HStack(spacing: 8) {
                    Spacer()
                    if isActionInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        if let onUpdate {
                            dockerButton("Update", icon: "arrow.down.circle", color: .blue) {
                                onUpdate()
                            }
                        }
                        if let onAction {
                            if container.isRunning {
                                dockerButton("Restart", icon: "arrow.clockwise", color: .orange) {
                                    onAction("restart")
                                }
                                dockerButton("Stop", icon: "stop.fill", color: .red) {
                                    onAction("stop")
                                }
                            } else {
                                dockerButton("Start", icon: "play.fill", color: .green) {
                                    onAction("start")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func dockerButton(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ProxmoxRow: View {
    let guest: ProxmoxGuest
    var isActionInProgress: Bool = false
    var onAction: ((String) -> Void)? = nil
    var onConsole: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(guest.isRunning ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(guest.name)
                            .font(.subheadline.bold())
                            .lineLimit(1)
                        Text(guest.typeLabel)
                            .font(.system(size: 9).bold())
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(guest.type == "lxc" ? Color.teal.opacity(0.15) : Color.purple.opacity(0.15))
                            .foregroundStyle(guest.type == "lxc" ? .teal : .purple)
                            .clipShape(Capsule())
                    }
                    HStack(spacing: 8) {
                        Text("ID: \(guest.id)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !guest.node.isEmpty {
                            Text(guest.node)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let uptime = guest.formattedUptime {
                            Text(uptime)
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                    }
                    if !guest.ipAddress.isEmpty {
                        Text(guest.ipAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }

                    if guest.isRunning {
                        HStack(spacing: 12) {
                            usageBar(
                                label: "CPU",
                                value: guest.cpuUsage,
                                detail: "\(Int(guest.cpuUsage * 100))%",
                                color: guest.cpuUsage > 0.9 ? .red : guest.cpuUsage > 0.7 ? .orange : .blue
                            )
                            usageBar(
                                label: "MEM",
                                value: guest.memoryPercent,
                                detail: String(format: "%.1f/%.1f GB", Double(guest.memUsedMB) / 1024.0, Double(guest.memoryMB) / 1024.0),
                                color: guest.memoryPercent > 0.9 ? .red : guest.memoryPercent > 0.7 ? .orange : .green
                            )
                        }
                    }
                }
                Spacer()
                Text(guest.isRunning ? "Running" : "Stopped")
                    .font(.caption2.bold())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background((guest.isRunning ? Color.green : Color.red).opacity(0.15))
                    .foregroundStyle(guest.isRunning ? .green : .red)
                    .clipShape(Capsule())
            }

            if let onAction {
                HStack(spacing: 6) {
                    if guest.isRunning, let onConsole {
                        proxmoxButton("Console", icon: "terminal", color: .blue) {
                            onConsole()
                        }
                    }
                    Spacer()
                    if isActionInProgress {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        if guest.isRunning {
                            proxmoxIconButton(icon: "arrow.clockwise", color: .orange, tooltip: "Reboot") {
                                onAction("reboot")
                            }
                            proxmoxIconButton(icon: "power", color: .yellow, tooltip: "Shutdown") {
                                onAction("shutdown")
                            }
                            proxmoxIconButton(icon: "stop.fill", color: .red, tooltip: "Stop") {
                                onAction("stop")
                            }
                        } else {
                            proxmoxButton("Start", icon: "play.fill", color: .green) {
                                onAction("start")
                            }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func usageBar(label: String, value: Double, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9).bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(detail)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * min(value, 1.0)))
                }
            }
            .frame(height: 4)
        }
    }

    private func proxmoxButton(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
                .font(.caption2.bold())
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12))
                .foregroundStyle(color)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func proxmoxIconButton(icon: String, color: Color, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.caption2.bold())
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .foregroundStyle(color)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}

// MARK: - Sparkline

struct SparklineView: View {
    let data: [Double]
    var color: Color = .blue

    var body: some View {
        GeometryReader { geo in
            let lo = max((data.min() ?? 0) - 0.05, 0)
            let hi = max((data.max() ?? 1) + 0.05, lo + 0.01)
            let w = geo.size.width
            let h = geo.size.height

            let points: [CGPoint] = data.enumerated().map { i, val in
                let x = data.count > 1 ? w * CGFloat(i) / CGFloat(data.count - 1) : w / 2
                let y = h - h * CGFloat((val - lo) / (hi - lo))
                return CGPoint(x: x, y: y)
            }

            ZStack {
                // Fill
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: h))
                    path.addLine(to: first)
                    for pt in points.dropFirst() { path.addLine(to: pt) }
                    path.addLine(to: CGPoint(x: points.last!.x, y: h))
                    path.closeSubpath()
                }
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.25), color.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom
                    )
                )

                // Line
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    for pt in points.dropFirst() { path.addLine(to: pt) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
