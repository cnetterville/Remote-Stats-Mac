//
//  ServerListView.swift
//  Remote Stats Mac
//

import SwiftUI

struct ServerStatus {
    var isOnline: Bool = false
    var uptime: String = ""
    var osType: OSType = .unknown
    var loadAverage: String = ""
    var memoryPercent: Double = 0
    var cpuCores: Int = 0
    var latencyMs: Double? = nil
    var isChecking: Bool = true
    var lastChecked: Date? = nil
}

extension ServerStatus: Codable {
    private enum CodingKeys: String, CodingKey { case isOnline, uptime, osType, loadAverage, memoryPercent, cpuCores, latencyMs, lastChecked }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isOnline, forKey: .isOnline)
        try c.encode(uptime, forKey: .uptime)
        try c.encode(osType, forKey: .osType)
        try c.encode(loadAverage, forKey: .loadAverage)
        try c.encode(memoryPercent, forKey: .memoryPercent)
        try c.encode(cpuCores, forKey: .cpuCores)
        try c.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try c.encodeIfPresent(lastChecked, forKey: .lastChecked)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOnline      = try c.decode(Bool.self,   forKey: .isOnline)
        uptime        = try c.decode(String.self, forKey: .uptime)
        osType        = try c.decode(OSType.self, forKey: .osType)
        loadAverage   = (try? c.decode(String.self, forKey: .loadAverage)) ?? ""
        memoryPercent = (try? c.decode(Double.self, forKey: .memoryPercent)) ?? 0
        cpuCores      = (try? c.decode(Int.self, forKey: .cpuCores)) ?? 0
        latencyMs     = try? c.decode(Double.self, forKey: .latencyMs)
        lastChecked   = try c.decodeIfPresent(Date.self, forKey: .lastChecked)
        isChecking    = false
    }
}

struct ServerListView: View {
    @Environment(ServerStore.self) private var store
    @State private var showAddServer = false
    @State private var editingServer: ServerConfig? = nil
    @AppStorage("refreshInterval") private var refreshInterval = 0

    private var existingTags: [String] {
        Array(Set(store.servers.map(\.tag).filter { !$0.isEmpty })).sorted()
    }

    private var groupedServers: [(tag: String, servers: [ServerConfig])] {
        let tagged = Dictionary(grouping: store.servers.filter { !$0.tag.isEmpty }, by: \.tag)
        let untagged = store.servers.filter { $0.tag.isEmpty }
        var sections: [(tag: String, servers: [ServerConfig])] = tagged.keys.sorted().map { ($0, tagged[$0]!) }
        if !untagged.isEmpty {
            sections.append(("", untagged))
        }
        return sections
    }

    private var hasAnyTags: Bool {
        store.servers.contains { !$0.tag.isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.servers.isEmpty {
                    emptyState
                } else {
                    serverList
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        Image(systemName: "server.rack")
                            .foregroundStyle(.blue)
                        Text("Servers")
                            .font(.headline)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showAddServer = true } label: {
                        Image(systemName: "plus.circle.fill").font(.title3)
                    }
                }
            }
            .sheet(isPresented: $showAddServer) {
                AddServerView(existingTags: existingTags) { server in
                    store.add(server)
                    checkStatus(for: server)
                }
            }
            .sheet(item: $editingServer) { server in
                AddServerView(existingServer: server, existingTags: existingTags) { updated in
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

    private var serverList: some View {
        List {
            if hasAnyTags {
                ForEach(groupedServers, id: \.tag) { section in
                    Section(section.tag.isEmpty ? "Other" : section.tag) {
                        serverRows(for: section.servers)
                    }
                }
            } else {
                serverRows(for: store.servers)
            }
        }
    }

    private func serverRows(for servers: [ServerConfig]) -> some View {
        ForEach(servers) { server in
            NavigationLink(destination: ServerDetailView(server: server).environment(store)) {
                ServerRow(server: server, status: store.statuses[server.id])
            }
            .contextMenu {
                Button {
                    editingServer = server
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    if let idx = store.servers.firstIndex(where: { $0.id == server.id }) {
                        store.delete(at: IndexSet(integer: idx))
                    }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .onMove { localSource, localDestination in
            let ids = servers.map(\.id)
            let movedIDs = localSource.map { ids[$0] }
            guard let firstMovedIdx = store.servers.firstIndex(where: { $0.id == movedIDs.first }) else { return }

            let destID: UUID? = localDestination < ids.count ? ids[localDestination] : nil
            let storeDestination: Int
            if let destID, let idx = store.servers.firstIndex(where: { $0.id == destID }) {
                storeDestination = idx
            } else if let lastID = ids.last, let idx = store.servers.firstIndex(where: { $0.id == lastID }) {
                storeDestination = idx + 1
            } else {
                storeDestination = store.servers.endIndex
            }

            store.move(fromOffsets: IndexSet(integer: firstMovedIdx), toOffset: storeDestination)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("No Servers Yet")
                .font(.title2.bold())
            Text("Tap + to add your first remote server.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                showAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus").font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Status Checking

    private func refreshAllStatuses(force: Bool = false) async {
        for server in store.servers {
            if force {
                // Pull-to-refresh: show spinner over everything
                store.statuses[server.id] = ServerStatus(isChecking: true)
            } else if store.statuses[server.id] == nil {
                // No cached data: show spinner
                store.statuses[server.id] = ServerStatus(isChecking: true)
            }
            // Has cached data: leave visible, update silently in background
        }
        await withTaskGroup(of: (UUID, Bool, String, OSType, String, Double, Int, Double?).self) { group in
            for server in store.servers {
                let cachedOS = store.statuses[server.id]?.osType
                group.addTask {
                    let r = await SSHService.checkStatus(for: server, knownOSType: cachedOS)
                    return (server.id, r.isOnline, r.uptime, r.osType, r.loadAverage, r.memoryPercent, r.cpuCores, r.latencyMs)
                }
            }
            for await (id, isOnline, uptime, osType, load, mem, cores, latency) in group {
                store.statuses[id] = ServerStatus(isOnline: isOnline, uptime: uptime, osType: osType, loadAverage: load, memoryPercent: mem, cpuCores: cores, latencyMs: latency, isChecking: false, lastChecked: Date())
            }
        }
        store.saveStatuses()
    }

    private func checkStatus(for server: ServerConfig) {
        store.statuses[server.id] = ServerStatus(isChecking: true)
        Task {
            let r = await SSHService.checkStatus(for: server)
            store.statuses[server.id] = ServerStatus(
                isOnline: r.isOnline,
                uptime: r.uptime,
                osType: r.osType,
                loadAverage: r.loadAverage,
                memoryPercent: r.memoryPercent,
                cpuCores: r.cpuCores,
                latencyMs: r.latencyMs,
                isChecking: false,
                lastChecked: Date()
            )
            store.saveStatuses()
        }
    }
}

// MARK: - Server Row

struct ServerRow: View {
    let server: ServerConfig
    let status: ServerStatus?

    var body: some View {
        HStack(spacing: 12) {
            osIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(server.port == 22 ? server.host : "\(server.host):\(String(server.port))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            uptimeTrailing
                .fixedSize()
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var osIcon: some View {
        if let status, !status.isChecking {
            if case .windows = status.osType {
                WindowsLogoView()
                    .frame(width: 24, height: 24)
            } else if case .linux(let distro) = status.osType, distro == "raspbian" {
                RaspberryPiLogoView()
                    .frame(width: 24, height: 24)
            } else {
                Text(status.osType.emoji)
                    .font(.title2)
            }
        } else {
            Text("\u{1F5A5}\u{FE0F}")
                .font(.title2)
                .opacity(status?.isChecking == true ? 0 : 1)
        }
    }

    @ViewBuilder
    private var uptimeTrailing: some View {
        if let status {
            if status.isChecking {
                ProgressView()
                    .scaleEffect(0.75)
            } else {
                VStack(alignment: .trailing, spacing: 4) {
                    if status.isOnline {
                        Text(status.uptime)
                            .font(.callout)
                            .foregroundStyle(.green)
                            .monospacedDigit()
                            .lineLimit(1)
                        HStack(spacing: 8) {
                            if !status.loadAverage.isEmpty, status.cpuCores > 0,
                               let load = Double(status.loadAverage) {
                                let cpuPct = min(load / Double(status.cpuCores), 1.0)
                                HStack(spacing: 3) {
                                    Image(systemName: "cpu")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                    Text("\(Int(cpuPct * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(cpuTint(cpuPct))
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                            if status.memoryPercent > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "memorychip")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                    Text("\(Int(status.memoryPercent * 100))%")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(memoryTint(status.memoryPercent))
                                        .lineLimit(1)
                                        .fixedSize()
                                }
                            }
                        }
                    } else {
                        Text("Offline")
                            .font(.callout)
                            .foregroundStyle(.red)
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
}

// MARK: - Windows Logo

struct WindowsLogoView: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let gap = w * 0.06
            let midX = w * 0.46
            let midY = h * 0.5

            // Top-left pane
            var tl = Path()
            tl.move(to: CGPoint(x: 0, y: h * 0.14))
            tl.addLine(to: CGPoint(x: midX - gap / 2, y: h * 0.08))
            tl.addLine(to: CGPoint(x: midX - gap / 2, y: midY - gap / 2))
            tl.addLine(to: CGPoint(x: 0, y: midY - gap / 2))
            tl.closeSubpath()
            context.fill(tl, with: .color(Color(red: 0, green: 0.47, blue: 0.83)))

            // Top-right pane
            var tr = Path()
            tr.move(to: CGPoint(x: midX + gap / 2, y: h * 0.07))
            tr.addLine(to: CGPoint(x: w, y: 0))
            tr.addLine(to: CGPoint(x: w, y: midY - gap / 2))
            tr.addLine(to: CGPoint(x: midX + gap / 2, y: midY - gap / 2))
            tr.closeSubpath()
            context.fill(tr, with: .color(Color(red: 0, green: 0.47, blue: 0.83)))

            // Bottom-left pane
            var bl = Path()
            bl.move(to: CGPoint(x: 0, y: midY + gap / 2))
            bl.addLine(to: CGPoint(x: midX - gap / 2, y: midY + gap / 2))
            bl.addLine(to: CGPoint(x: midX - gap / 2, y: h * 0.92))
            bl.addLine(to: CGPoint(x: 0, y: h * 0.86))
            bl.closeSubpath()
            context.fill(bl, with: .color(Color(red: 0, green: 0.47, blue: 0.83)))

            // Bottom-right pane
            var br = Path()
            br.move(to: CGPoint(x: midX + gap / 2, y: midY + gap / 2))
            br.addLine(to: CGPoint(x: w, y: midY + gap / 2))
            br.addLine(to: CGPoint(x: w, y: h))
            br.addLine(to: CGPoint(x: midX + gap / 2, y: h * 0.93))
            br.closeSubpath()
            context.fill(br, with: .color(Color(red: 0, green: 0.47, blue: 0.83)))
        }
    }
}

struct RaspberryPiLogoView: View {
    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let berry = Color(red: 0.74, green: 0.1, blue: 0.28)
            let leaf = Color(red: 0.2, green: 0.6, blue: 0.2)

            let r = w * 0.12

            // Berry: 10 overlapping circles in a raspberry cluster
            let berryCircles: [(CGFloat, CGFloat)] = [
                (0.50, 0.42),
                (0.34, 0.48), (0.66, 0.48),
                (0.26, 0.58), (0.50, 0.56), (0.74, 0.58),
                (0.32, 0.70), (0.68, 0.70),
                (0.40, 0.82), (0.60, 0.82),
            ]
            for (px, py) in berryCircles {
                let rect = CGRect(x: w * px - r, y: h * py - r, width: r * 2, height: r * 2)
                context.fill(Path(ellipseIn: rect), with: .color(berry))
            }

            // Left leaf
            var ll = Path()
            ll.move(to: CGPoint(x: w * 0.48, y: h * 0.35))
            ll.addQuadCurve(to: CGPoint(x: w * 0.18, y: h * 0.18),
                            control: CGPoint(x: w * 0.22, y: h * 0.38))
            ll.addQuadCurve(to: CGPoint(x: w * 0.48, y: h * 0.35),
                            control: CGPoint(x: w * 0.38, y: h * 0.14))
            ll.closeSubpath()
            context.fill(ll, with: .color(leaf))

            // Right leaf
            var rl = Path()
            rl.move(to: CGPoint(x: w * 0.52, y: h * 0.35))
            rl.addQuadCurve(to: CGPoint(x: w * 0.82, y: h * 0.18),
                            control: CGPoint(x: w * 0.78, y: h * 0.38))
            rl.addQuadCurve(to: CGPoint(x: w * 0.52, y: h * 0.35),
                            control: CGPoint(x: w * 0.62, y: h * 0.14))
            rl.closeSubpath()
            context.fill(rl, with: .color(leaf))
        }
    }
}
