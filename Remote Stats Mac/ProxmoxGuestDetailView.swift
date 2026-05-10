//
//  ProxmoxGuestDetailView.swift
//  Remote Stats Mac
//

import SwiftUI

@Observable
@MainActor
class ProxmoxGuestViewModel {
    var guest: ProxmoxGuest
    let server: ServerConfig
    var config: ProxmoxGuestConfig?
    var snapshots: [ProxmoxSnapshot] = []
    var backups: [ProxmoxBackup] = []
    var backupStorages: [String] = []
    var tasks: [ProxmoxTask] = []
    var isLoading = false
    var actionInProgress = false
    var errorMessage: String?

    init(guest: ProxmoxGuest, server: ServerConfig) {
        self.guest = guest
        self.server = server
    }

    func loadAll() async {
        isLoading = true
        errorMessage = nil
        async let c = try? SSHService.fetchProxmoxGuestConfig(guest: guest, config: server)
        async let s = try? SSHService.fetchProxmoxSnapshots(guest: guest, config: server)
        async let b = try? SSHService.fetchProxmoxBackups(guest: guest, config: server)
        async let bs = try? SSHService.fetchBackupStorages(node: guest.node, config: server)
        async let t = try? SSHService.fetchProxmoxTasks(guest: guest, config: server)
        async let g = try? SSHService.fetchProxmoxGuests(config: server)
        config = await c
        snapshots = await s ?? []
        backups = await b ?? []
        backupStorages = await bs ?? []
        tasks = await t ?? []
        if let guests = await g, let updated = guests.first(where: { $0.id == guest.id }) {
            guest = updated
        }
        if guest.isRunning && guest.ipAddress.isEmpty {
            let ips = await SSHService.fetchProxmoxGuestIPs(guests: [guest], config: server)
            if let ip = ips[guest.id] {
                guest.ipAddress = ip
            }
        }
        isLoading = false
    }

    func performAction(_ action: String) async {
        actionInProgress = true
        errorMessage = nil
        do {
            try await SSHService.proxmoxAction(action, guest: guest, config: server)
            try await Task.sleep(for: .seconds(2))
            if let guests = try await SSHService.fetchProxmoxGuests(config: server).first(where: { $0.id == guest.id }) {
                guest = guests
            }
        } catch {
            errorMessage = "\(action) failed: \(error.localizedDescription)"
        }
        actionInProgress = false
    }

    func createSnapshot(name: String, description: String) async {
        actionInProgress = true
        errorMessage = nil
        do {
            try await SSHService.createProxmoxSnapshot(guest: guest, name: name, description: description, config: server)
            snapshots = (try? await SSHService.fetchProxmoxSnapshots(guest: guest, config: server)) ?? snapshots
        } catch {
            errorMessage = "Snapshot failed: \(error.localizedDescription)"
        }
        actionInProgress = false
    }

    func deleteSnapshot(_ name: String) async {
        actionInProgress = true
        errorMessage = nil
        do {
            try await SSHService.deleteProxmoxSnapshot(guest: guest, snapshotName: name, config: server)
            snapshots = (try? await SSHService.fetchProxmoxSnapshots(guest: guest, config: server)) ?? snapshots
        } catch {
            errorMessage = "Delete snapshot failed: \(error.localizedDescription)"
        }
        actionInProgress = false
    }

    func createBackup(storage: String, mode: String, compress: String) async {
        actionInProgress = true
        errorMessage = nil
        do {
            try await SSHService.createProxmoxBackup(guest: guest, storage: storage, mode: mode, compress: compress, config: server)
            backups = (try? await SSHService.fetchProxmoxBackups(guest: guest, config: server)) ?? backups
        } catch {
            errorMessage = "Backup failed: \(error.localizedDescription)"
        }
        actionInProgress = false
    }

    func deleteBackup(_ volid: String) async {
        actionInProgress = true
        errorMessage = nil
        do {
            try await SSHService.deleteProxmoxBackup(node: guest.node, volid: volid, config: server)
            backups = (try? await SSHService.fetchProxmoxBackups(guest: guest, config: server)) ?? backups
        } catch {
            errorMessage = "Delete backup failed: \(error.localizedDescription)"
        }
        actionInProgress = false
    }

    func rollbackSnapshot(_ name: String) async {
        actionInProgress = true
        errorMessage = nil
        do {
            try await SSHService.rollbackProxmoxSnapshot(guest: guest, snapshotName: name, config: server)
            snapshots = (try? await SSHService.fetchProxmoxSnapshots(guest: guest, config: server)) ?? snapshots
        } catch {
            errorMessage = "Rollback failed: \(error.localizedDescription)"
        }
        actionInProgress = false
    }
}

struct ProxmoxGuestDetailView: View {
    let initialGuest: ProxmoxGuest
    let server: ServerConfig
    @State private var viewModel: ProxmoxGuestViewModel
    @State private var showSnapshotSheet = false
    @State private var showBackupSheet = false
    @State private var showRollbackConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showDeleteBackupConfirm = false
    @State private var selectedSnapshot: String?
    @State private var selectedBackupVolid: String?
    @State private var navigateToConsole = false
    @State private var pendingConsoleCommand: String?

    init(guest: ProxmoxGuest, server: ServerConfig) {
        self.initialGuest = guest
        self.server = server
        self._viewModel = State(initialValue: ProxmoxGuestViewModel(guest: guest, server: server))
    }

    private var guest: ProxmoxGuest { viewModel.guest }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                statusCard
                resourceCard
                if let config = viewModel.config {
                    configCard(config)
                }
                controlsCard
                snapshotCard
                backupCard
                taskCard
            }
            .padding()
        }
        .navigationTitle(guest.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isLoading {
                    ProgressView()
                }
            }
        }
        .task { await viewModel.loadAll() }
        .refreshable { await viewModel.loadAll() }
        .sheet(isPresented: $showSnapshotSheet) {
            CreateSnapshotSheet { name, desc in
                Task { await viewModel.createSnapshot(name: name, description: desc) }
            }
        }
        .sheet(isPresented: $showBackupSheet) {
            CreateBackupSheet(storages: viewModel.backupStorages) { storage, mode, compress in
                Task { await viewModel.createBackup(storage: storage, mode: mode, compress: compress) }
            }
        }
        .confirmationDialog("Rollback Snapshot", isPresented: $showRollbackConfirm) {
            Button("Rollback", role: .destructive) {
                if let name = selectedSnapshot {
                    Task { await viewModel.rollbackSnapshot(name) }
                }
            }
        } message: {
            Text("This will revert the \(guest.typeLabel) to snapshot \"\(selectedSnapshot ?? "")\". This cannot be undone.")
        }
        .confirmationDialog("Delete Snapshot", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive) {
                if let name = selectedSnapshot {
                    Task { await viewModel.deleteSnapshot(name) }
                }
            }
        } message: {
            Text("Delete snapshot \"\(selectedSnapshot ?? "")\"? This cannot be undone.")
        }
        .confirmationDialog("Delete Backup", isPresented: $showDeleteBackupConfirm) {
            Button("Delete", role: .destructive) {
                if let volid = selectedBackupVolid {
                    Task { await viewModel.deleteBackup(volid) }
                }
            }
        } message: {
            Text("Delete this backup? This cannot be undone.")
        }
        .navigationDestination(isPresented: $navigateToConsole) {
            if #available(macOS 15.0, *), let cmd = pendingConsoleCommand {
                TerminalView(server: server, initialCommand: cmd)
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    // MARK: - Status Card

    private var statusCard: some View {
        StatCard(title: "\(guest.typeLabel) — \(guest.name)", icon: guest.type == "lxc" ? "cube" : "desktopcomputer", color: .orange) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(guest.isRunning ? Color.green : Color.red)
                            .frame(width: 10, height: 10)
                        Text(guest.status.capitalized)
                            .font(.title3.bold())
                    }
                    Text("VMID \(guest.id)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !guest.node.isEmpty {
                        Text("Node: \(guest.node)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !guest.ipAddress.isEmpty {
                        Text(guest.ipAddress)
                            .font(.caption.monospaced())
                            .foregroundStyle(.blue)
                    }
                }
                Spacer()
                if let uptime = guest.formattedUptime {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Uptime")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(uptime)
                            .font(.title3.bold().monospacedDigit())
                            .foregroundStyle(.green)
                    }
                }
            }
        }
    }

    // MARK: - Resource Card

    private var resourceCard: some View {
        StatCard(title: "Resources", icon: "gauge.with.dots.needle.50percent", color: .blue) {
            VStack(spacing: 12) {
                if guest.isRunning {
                    resourceBar(label: "CPU", value: guest.cpuUsage,
                                detail: "\(Int(guest.cpuUsage * 100))% of \(guest.cpuCount) core\(guest.cpuCount == 1 ? "" : "s")",
                                color: guest.cpuUsage > 0.9 ? .red : guest.cpuUsage > 0.7 ? .orange : .blue)
                    resourceBar(label: "Memory", value: guest.memoryPercent,
                                detail: String(format: "%.1f / %.1f GB (%d%%)", Double(guest.memUsedMB) / 1024.0, Double(guest.memoryMB) / 1024.0, Int(guest.memoryPercent * 100)),
                                color: guest.memoryPercent > 0.9 ? .red : guest.memoryPercent > 0.7 ? .orange : .green)
                } else {
                    HStack {
                        Text("Allocated")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack(spacing: 16) {
                        resourceStat(label: "CPU", value: "\(guest.cpuCount) cores")
                        resourceStat(label: "Memory", value: String(format: "%.1f GB", Double(guest.memoryMB) / 1024.0))
                        resourceStat(label: "Disk", value: String(format: "%.1f GB", guest.diskGB))
                    }
                }
                if guest.isRunning && guest.diskGB > 0 {
                    HStack {
                        Image(systemName: "internaldrive")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.1f GB disk", guest.diskGB))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
            }
        }
    }

    // MARK: - Configuration Card

    private func configCard(_ config: ProxmoxGuestConfig) -> some View {
        StatCard(title: "Configuration", icon: "gearshape", color: .purple) {
            VStack(spacing: 8) {
                if config.cores > 0 {
                    configRow("CPU", value: "\(config.cores) cores \(config.sockets > 1 ? "× \(config.sockets) sockets" : "")")
                }
                if config.memoryMB > 0 {
                    configRow("Memory", value: String(format: "%.1f GB", Double(config.memoryMB) / 1024.0))
                }
                if !config.osType.isEmpty {
                    configRow("OS Type", value: config.osType)
                }
                if !config.networkInterfaces.isEmpty {
                    Divider()
                    ForEach(config.networkInterfaces) { nic in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(nic.name.uppercased())
                                    .font(.caption.bold())
                                    .foregroundStyle(.purple)
                                if !nic.model.isEmpty {
                                    Text(nic.model)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if nic.firewall {
                                    Image(systemName: "flame.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                            HStack(spacing: 12) {
                                if !nic.bridge.isEmpty {
                                    Text("Bridge: \(nic.bridge)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if !nic.hwaddr.isEmpty {
                                    Text(nic.hwaddr)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                if let tag = nic.tag {
                                    Text("VLAN \(tag)")
                                        .font(.caption)
                                        .foregroundStyle(.teal)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Controls Card

    private var controlsCard: some View {
        StatCard(title: "Controls", icon: "power", color: .green) {
            if viewModel.actionInProgress {
                HStack {
                    Spacer()
                    ProgressView("Working...")
                    Spacer()
                }
            } else {
                VStack(spacing: 10) {
                    if guest.isRunning {
                        HStack(spacing: 10) {
                            if guest.type == "lxc" {
                                actionButton("Console", icon: "terminal", color: .blue) {
                                    pendingConsoleCommand = "pct enter \(guest.id)"
                                    navigateToConsole = true
                                }
                            }
                            actionButton("Reboot", icon: "arrow.clockwise", color: .orange) {
                                Task { await viewModel.performAction("reboot") }
                            }
                            actionButton("Shutdown", icon: "power", color: .yellow) {
                                Task { await viewModel.performAction("shutdown") }
                            }
                            actionButton("Stop", icon: "stop.fill", color: .red) {
                                Task { await viewModel.performAction("stop") }
                            }
                        }
                    } else {
                        HStack {
                            actionButton("Start", icon: "play.fill", color: .green) {
                                Task { await viewModel.performAction("start") }
                            }
                            Spacer()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Snapshot Card

    private var snapshotCard: some View {
        StatCard(title: "Snapshots (\(viewModel.snapshots.count))", icon: "camera", color: .indigo) {
            VStack(spacing: 8) {
                Button {
                    showSnapshotSheet = true
                } label: {
                    Label("New Snapshot", systemImage: "plus.circle.fill")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(Color.indigo.opacity(0.12))
                        .foregroundStyle(.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.actionInProgress)

                if viewModel.snapshots.isEmpty && !viewModel.isLoading {
                    Text("No snapshots")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.snapshots) { snap in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "camera.fill")
                                    .font(.caption)
                                    .foregroundStyle(.indigo)
                                Text(snap.name)
                                    .font(.subheadline.bold())
                                Spacer()
                                if !snap.formattedDate.isEmpty {
                                    Text(snap.formattedDate)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !snap.description.isEmpty {
                                Text(snap.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            HStack(spacing: 8) {
                                Spacer()
                                Button {
                                    selectedSnapshot = snap.name
                                    showRollbackConfirm = true
                                } label: {
                                    Label("Rollback", systemImage: "arrow.uturn.backward")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.orange.opacity(0.12))
                                        .foregroundStyle(.orange)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    selectedSnapshot = snap.name
                                    showDeleteConfirm = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.red.opacity(0.12))
                                        .foregroundStyle(.red)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 4)
                        if snap.id != viewModel.snapshots.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Backup Card

    private var backupCard: some View {
        StatCard(title: "Backups (\(viewModel.backups.count))", icon: "externaldrive.fill.badge.timemachine", color: .cyan) {
            VStack(spacing: 8) {
                if !viewModel.backupStorages.isEmpty {
                    Button {
                        showBackupSheet = true
                    } label: {
                        Label("New Backup", systemImage: "plus.circle.fill")
                            .font(.subheadline.bold())
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color.cyan.opacity(0.12))
                            .foregroundStyle(.cyan)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.actionInProgress)
                }

                if viewModel.backups.isEmpty && !viewModel.isLoading {
                    Text("No backups found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    ForEach(viewModel.backups) { backup in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "externaldrive.fill")
                                    .font(.caption)
                                    .foregroundStyle(.cyan)
                                Text(backup.formattedDate)
                                    .font(.subheadline.bold())
                                Spacer()
                                Text(backup.formattedSize)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            HStack(spacing: 8) {
                                Text(backup.storage)
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.cyan.opacity(0.15))
                                    .foregroundStyle(.cyan)
                                    .clipShape(Capsule())
                                if !backup.format.isEmpty {
                                    Text(backup.format)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button {
                                    selectedBackupVolid = backup.volid
                                    showDeleteBackupConfirm = true
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.red.opacity(0.12))
                                        .foregroundStyle(.red)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            if !backup.notes.isEmpty {
                                Text(backup.notes)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(.vertical, 4)
                        if backup.id != viewModel.backups.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Task Card

    private var taskCard: some View {
        StatCard(title: "Recent Tasks", icon: "list.bullet.clipboard", color: .teal) {
            if viewModel.tasks.isEmpty && !viewModel.isLoading {
                Text("No recent tasks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(viewModel.tasks) { task in
                        HStack(spacing: 8) {
                            Image(systemName: task.isOK ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(task.isOK ? .green : .red)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.type)
                                    .font(.caption.bold())
                                HStack(spacing: 6) {
                                    if !task.formattedStart.isEmpty {
                                        Text(task.formattedStart)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    if let dur = task.duration {
                                        Text(dur)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if !task.isOK {
                                Text(task.status)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                        if task.id != viewModel.tasks.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func resourceBar(label: String, value: Double, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline.bold())
                Spacer()
                Text(detail)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(color)
                        .frame(width: max(0, geo.size.width * min(value, 1.0)))
                }
            }
            .frame(height: 8)
        }
    }

    private func resourceStat(label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.bold())
        }
    }

    private func configRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.bold())
        }
    }

    private func actionButton(_ label: String, icon: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2.bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(color.opacity(0.12))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Create Snapshot Sheet

struct CreateSnapshotSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var description = ""
    var onCreate: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Snapshot Name") {
                    TextField("e.g. before-update", text: $name)
                        .autocorrectionDisabled()
                }
                Section("Description (optional)") {
                    TextField("What is this snapshot for?", text: $description)
                }
            }
            .navigationTitle("New Snapshot")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        onCreate(name, description)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Create Backup Sheet

struct CreateBackupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let storages: [String]
    @State private var selectedStorage: String = ""
    @State private var mode = "snapshot"
    @State private var compress = "zstd"
    var onCreate: (String, String, String) -> Void

    private let modes = ["snapshot", "suspend", "stop"]
    private let compressions = ["zstd", "lzo", "gzip", "none"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Storage") {
                    Picker("Destination", selection: $selectedStorage) {
                        ForEach(storages, id: \.self) { storage in
                            Text(storage).tag(storage)
                        }
                    }
                }
                Section("Backup Mode") {
                    Picker("Mode", selection: $mode) {
                        ForEach(modes, id: \.self) { m in
                            Text(m.capitalized).tag(m)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section("Compression") {
                    Picker("Compression", selection: $compress) {
                        ForEach(compressions, id: \.self) { c in
                            Text(c == "none" ? "None" : c.uppercased()).tag(c)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("New Backup")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Backup") {
                        onCreate(selectedStorage, mode, compress)
                        dismiss()
                    }
                    .disabled(selectedStorage.isEmpty)
                }
            }
            .onAppear {
                if selectedStorage.isEmpty, let first = storages.first {
                    selectedStorage = first
                }
            }
        }
    }
}
