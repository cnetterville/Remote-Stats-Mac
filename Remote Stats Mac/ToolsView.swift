//
//  ToolsView.swift
//  Remote Stats Mac
//

import SwiftUI
import Charts
import Citadel
import NIOCore
import Network
import os

enum NetworkTool: String, CaseIterable, Identifiable {
    case ping = "Ping"
    case traceroute = "Traceroute"
    case dnsLookup = "DNS Lookup"
    case portCheck = "Port Check"
    case iperfDownload = "iPerf ↓"
    case iperfUpload = "iPerf ↑"
    case lanScan = "LAN Scan"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .ping: return "dot.radiowaves.left.and.right"
        case .traceroute: return "point.topleft.down.to.point.bottomright.curvepath"
        case .dnsLookup: return "magnifyingglass"
        case .portCheck: return "door.left.hand.open"
        case .iperfDownload: return "arrow.down.circle"
        case .iperfUpload: return "arrow.up.circle"
        case .lanScan: return "network"
        }
    }

    var description: String {
        switch self {
        case .ping: return "ICMP ping to measure latency and packet loss"
        case .traceroute: return "Trace the network path to a host, showing each hop"
        case .dnsLookup: return "Query DNS records for a domain from the server"
        case .portCheck: return "Test if a specific TCP port is open on a host"
        case .iperfDownload: return "iPerf3 download speed test (server → target)"
        case .iperfUpload: return "iPerf3 upload speed test (target → server)"
        case .lanScan: return "Discover devices on your local network"
        }
    }

    var availableLocally: Bool {
        switch self {
        case .ping, .dnsLookup, .portCheck, .lanScan: return true
        case .traceroute, .iperfDownload, .iperfUpload: return false
        }
    }

    var needsTarget: Bool {
        switch self {
        case .lanScan: return false
        default: return true
        }
    }

    var targetPlaceholder: String {
        switch self {
        case .dnsLookup: return "e.g. example.com"
        case .portCheck: return "e.g. 192.168.1.1 or example.com"
        default: return "e.g. 1.1.1.1 or example.com"
        }
    }
}

struct DiscoveredHost: Identifiable {
    var id: String { ip }
    var ip: String
    var hostname: String?
    var openPorts: Set<Int> = []
    var services: [String] = []
    var isLocalDevice: Bool = false

    static let scanPorts = [22, 53, 80, 443, 445, 548, 631, 3389, 5353, 5900, 8080, 62078]

    static let portLabels: [Int: String] = [
        22: "SSH", 53: "DNS", 80: "HTTP", 443: "HTTPS",
        445: "SMB", 548: "AFP", 631: "IPP", 3389: "RDP",
        5353: "mDNS", 5900: "VNC", 8080: "HTTP", 62078: "iOS"
    ]

    var deviceIcon: String {
        if isLocalDevice { return "desktopcomputer" }
        if openPorts.contains(62078) { return "iphone" }
        if openPorts.contains(548) { return "desktopcomputer" }
        if openPorts.contains(3389) { return "pc" }
        if openPorts.contains(631) { return "printer.fill" }
        if openPorts.contains(22) { return "server.rack" }
        if openPorts.contains(80) || openPorts.contains(443) { return "globe" }
        return "wifi.router"
    }

    var sortableIP: UInt32 {
        let parts = ip.split(separator: ".").compactMap { UInt32($0) }
        guard parts.count == 4 else { return 0 }
        return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
    }
}

struct ThroughputSample: Identifiable {
    let id = UUID()
    var time: Double
    var mbps: Double
}

enum RunTarget: Hashable {
    case local
    case remote(ServerConfig)

    var displayName: String {
        switch self {
        case .local: return "This Mac"
        case .remote(let server): return server.name
        }
    }
}

@Observable
@MainActor
class ToolsViewModel {
    var selectedTarget: RunTarget? = .local
    var selectedTool: NetworkTool = .ping
    var targetHost: String = ""
    var isRunning = false
    var output: String = ""
    var pingCount: Int = 10
    var iperfDuration: Int = 10
    var iperfStreams: Int = 1
    var iperfPortText: String = "5201"
    var iperfPort: Int { Int(iperfPortText) ?? 5201 }
    var tracerouteMaxHops: Int = 30
    var dnsRecordType: String = "A"
    var portCheckPort: Int = 443
    var portCheckPortText: String = "443"
    var portCheckPortValue: Int { Int(portCheckPortText) ?? 443 }
    var portCheckTimeout: Int = 5

    var servers: [ServerConfig] = []
    var throughputSamples: [ThroughputSample] = []
    var hostHistory: [String] = []
    var discoveredHosts: [DiscoveredHost] = []
    var scanProgress: Double = 0
    var scanTotal: Int = 0
    var scanCompleted: Int = 0
    private static let historyKey = "toolsHostHistory"
    private static let maxHistory = 10
    private var runningTask: Task<Void, Never>?
    private var bonjourBrowsers: [NWBrowser] = []

    init() {
        hostHistory = UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? []
    }

    private func saveHostToHistory(_ host: String) {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hostHistory.removeAll { $0 == trimmed }
        hostHistory.insert(trimmed, at: 0)
        if hostHistory.count > Self.maxHistory {
            hostHistory = Array(hostHistory.prefix(Self.maxHistory))
        }
        UserDefaults.standard.set(hostHistory, forKey: Self.historyKey)
    }

    func removeFromHistory(_ host: String) {
        hostHistory.removeAll { $0 == host }
        UserDefaults.standard.set(hostHistory, forKey: Self.historyKey)
    }

    func run() {
        runningTask?.cancel()
        runningTask = Task { await performRun() }
    }

    func stop() {
        for browser in bonjourBrowsers { browser.cancel() }
        bonjourBrowsers.removeAll()
        runningTask?.cancel()
        runningTask = nil
    }

    private func performRun() async {
        guard let target = selectedTarget else { return }

        if selectedTool == .lanScan {
            isRunning = true
            discoveredHosts = []
            scanProgress = 0
            scanCompleted = 0
            scanTotal = 0
            output = ""
            await localLanScan()
            isRunning = false
            runningTask = nil
            return
        }

        let host = targetHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            output = "Please enter a target host."
            return
        }

        isRunning = true
        throughputSamples = []
        saveHostToHistory(host)

        switch target {
        case .local:
            output = "Running locally…\n\n"
            await runLocally(host: host)
        case .remote(let server):
            let command = buildCommand(target: host)
            output = "Connecting to \(server.name)…\n"
            output += "Running: \(command)\n\n"
            await runRemotely(command, on: server)
        }

        isRunning = false
        runningTask = nil
    }

    private func runRemotely(_ command: String, on server: ServerConfig) async {
        let isIperf = [.iperfDownload, .iperfUpload].contains(selectedTool)
        let iperfFilterTag = iperfStreams > 1 ? "[SUM]" : "[  5]"

        do {
            let client = try await SSHService.openConnection(for: server)
            defer { SSHService.closeConnection(client) }

            try Task.checkCancellation()
            let stream = try await client.executeCommandStream(command)
            var lineBuffer = ""
            var gotOutput = false

            for try await chunk in stream {
                let text: String
                switch chunk {
                case .stdout(let buffer):
                    text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
                case .stderr(let buffer):
                    text = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
                }

                guard !text.isEmpty else { continue }
                gotOutput = true
                output += text

                if isIperf {
                    lineBuffer += text
                    while let newlineRange = lineBuffer.range(of: "\n") {
                        let line = String(lineBuffer[lineBuffer.startIndex..<newlineRange.lowerBound])
                        lineBuffer = String(lineBuffer[newlineRange.upperBound...])
                        parseIperfLine(line, filterTag: iperfFilterTag)
                    }
                }
            }

            if isIperf && !lineBuffer.isEmpty {
                parseIperfLine(lineBuffer, filterTag: iperfFilterTag)
            }

            if !gotOutput {
                output += "No output received."
            }
        } catch is CancellationError {
            output += "\nCancelled."
        } catch {
            output += "\nError: \(error.localizedDescription)"
        }
    }

    private func parseIperfLine(_ line: String, filterTag: String) {
        guard line.contains(filterTag),
              !line.contains("sender"), !line.contains("receiver") else { return }

        guard let dashRange = line.range(of: #"(\d+\.?\d*)-(\d+\.?\d*)\s+sec"#, options: .regularExpression),
              let endTime = Double(line[dashRange].components(separatedBy: "-").last?.replacingOccurrences(of: " sec", with: "").trimmingCharacters(in: .whitespaces) ?? "") else { return }

        var mbps: Double?
        if let gbitsRange = line.range(of: #"(\d+\.?\d*)\s+Gbits/sec"#, options: .regularExpression) {
            let numStr = line[gbitsRange].replacingOccurrences(of: "Gbits/sec", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Double(numStr) { mbps = val * 1024 }
        } else if let mbitsRange = line.range(of: #"(\d+\.?\d*)\s+Mbits/sec"#, options: .regularExpression) {
            let numStr = line[mbitsRange].replacingOccurrences(of: "Mbits/sec", with: "").trimmingCharacters(in: .whitespaces)
            mbps = Double(numStr)
        } else if let kbitsRange = line.range(of: #"(\d+\.?\d*)\s+Kbits/sec"#, options: .regularExpression) {
            let numStr = line[kbitsRange].replacingOccurrences(of: "Kbits/sec", with: "").trimmingCharacters(in: .whitespaces)
            if let val = Double(numStr) { mbps = val / 1024 }
        }

        if let mbps {
            throughputSamples.append(ThroughputSample(time: endTime, mbps: mbps))
        }
    }

    // MARK: - Local execution using native APIs

    private func runLocally(host: String) async {
        switch selectedTool {
        case .ping:
            await localPing(host: host, count: pingCount)
        case .dnsLookup:
            await localDNS(host: host, recordType: dnsRecordType)
        case .portCheck:
            await localPortCheck(host: host, port: portCheckPortValue, timeout: portCheckTimeout)
        case .traceroute, .iperfDownload, .iperfUpload:
            output += "\(selectedTool.rawValue) is not available locally.\nSelect a remote server to use this tool."
        case .lanScan:
            break // handled separately in performRun
        }
    }

    private func localPing(host: String, count: Int) async {
        output += "PING \(host) — \(count) probes via TCP connect\n\n"
        var times: [Double] = []
        var failures = 0

        for i in 1...count {
            guard !Task.isCancelled else {
                output += "\n--- Cancelled after \(i - 1) probes ---\n"
                break
            }

            let start = CFAbsoluteTimeGetCurrent()
            let success = await tcpConnect(host: host, port: 80, timeout: 5)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

            if success {
                times.append(elapsed)
                output += "probe \(i): time=\(String(format: "%.1f", elapsed)) ms\n"
            } else {
                failures += 1
                output += "probe \(i): timeout\n"
            }

            if i < count {
                try? await Task.sleep(for: .seconds(1))
            }
        }

        let sent = times.count + failures
        let loss = sent > 0 ? Double(failures) / Double(sent) * 100 : 0
        output += "\n--- \(host) ping statistics ---\n"
        output += "\(sent) probes, \(failures) failed, \(String(format: "%.0f", loss))% loss\n"
        if !times.isEmpty {
            let minT = times.min()!
            let maxT = times.max()!
            let avg = times.reduce(0, +) / Double(times.count)
            output += "min/avg/max = \(String(format: "%.1f/%.1f/%.1f", minT, avg, maxT)) ms\n"
        }
    }

    private func tcpConnect(host: String, port: Int, timeout: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )
            let resumed = OSAllocatedUnfairLock(initialState: false)
            connection.stateUpdateHandler = { state in
                guard resumed.withLock({ old in let was = old; old = true; return !was }) else { return }
                switch state {
                case .ready:
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    continuation.resume(returning: false)
                default:
                    resumed.withLock { $0 = false }
                }
            }
            connection.start(queue: .global())

            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeout)) {
                guard resumed.withLock({ old in let was = old; old = true; return !was }) else { return }
                connection.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    private func localDNS(host: String, recordType: String) async {
        output += "Resolving \(host) (\(recordType))…\n\n"

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let hostRef = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
            var resolved = DarwinBoolean(false)

            CFHostStartInfoResolution(hostRef, .addresses, nil)
            guard let addresses = CFHostGetAddressing(hostRef, &resolved)?.takeUnretainedValue() as? [Data] else {
                self.output += "No results found.\n"
                continuation.resume()
                return
            }

            for addr in addresses {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                addr.withUnsafeBytes { ptr in
                    let sockaddr = ptr.bindMemory(to: sockaddr.self).baseAddress!
                    getnameinfo(sockaddr, socklen_t(addr.count), &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST)
                }
                let ip = String(cString: hostname)
                if !ip.isEmpty {
                    let isIPv6 = ip.contains(":")
                    if recordType == "AAAA" && isIPv6 {
                        self.output += "\(host) has AAAA address \(ip)\n"
                    } else if recordType == "A" && !isIPv6 {
                        self.output += "\(host) has A address \(ip)\n"
                    } else if recordType == "ANY" {
                        self.output += "\(host) has address \(ip)\n"
                    }
                }
            }

            if recordType != "A" && recordType != "AAAA" && recordType != "ANY" {
                self.output += "\nNote: Local DNS lookup only resolves A/AAAA records.\nUse a remote server for \(recordType) records.\n"
            }

            continuation.resume()
        }
    }

    private func localPortCheck(host: String, port: Int, timeout: Int) async {
        output += "Checking \(host):\(port)…\n\n"

        let start = CFAbsoluteTimeGetCurrent()
        let success = await tcpConnect(host: host, port: port, timeout: timeout)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        if success {
            output += "Connection to \(host) port \(port) [tcp] succeeded! (\(String(format: "%.0f", elapsed)) ms)\n"
        } else {
            output += "Connection to \(host) port \(port) [tcp] failed (timeout after \(timeout)s)\n"
        }
    }

    // MARK: - LAN Scan

    private func localLanScan() async {
        guard let netInfo = Self.getLocalNetworkInfo() else {
            output = "Could not determine local network. Make sure you're connected to WiFi or Ethernet."
            return
        }

        let localIP = netInfo.ip
        let subnetIPs = Self.subnetIPs(ip: netInfo.ip, mask: netInfo.mask)
        output = "Scanning \(subnetIPs.count) hosts on \(netInfo.ip)/\(netInfo.cidr)…\n"

        let ports = DiscoveredHost.scanPorts
        scanTotal = subnetIPs.count * ports.count
        scanCompleted = 0
        scanProgress = 0

        startBonjourDiscovery()

        await withTaskGroup(of: (String, Int, Bool).self) { group in
            let maxConcurrent = 80
            var queued = 0

            for ip in subnetIPs {
                for port in ports {
                    if queued >= maxConcurrent {
                        if let result = await group.next() {
                            processPortResult(result, localIP: localIP)
                        }
                    }
                    group.addTask { [self] in
                        let open = await tcpConnect(host: ip, port: port, timeout: 1)
                        return (ip, port, open)
                    }
                    queued += 1
                }
            }

            for await result in group {
                processPortResult(result, localIP: localIP)
            }
        }

        for i in discoveredHosts.indices {
            if let hostname = await resolveHostname(discoveredHosts[i].ip) {
                discoveredHosts[i].hostname = hostname
            }
        }

        for browser in bonjourBrowsers { browser.cancel() }
        bonjourBrowsers.removeAll()

        discoveredHosts.sort { $0.sortableIP < $1.sortableIP }

        output = "Scan complete — found \(discoveredHosts.count) device\(discoveredHosts.count == 1 ? "" : "s") on \(netInfo.ip)/\(netInfo.cidr)\n"
    }

    private func processPortResult(_ result: (String, Int, Bool), localIP: String) {
        let (ip, port, open) = result
        scanCompleted += 1
        scanProgress = Double(scanCompleted) / Double(max(scanTotal, 1))

        guard open else { return }

        if let idx = discoveredHosts.firstIndex(where: { $0.ip == ip }) {
            discoveredHosts[idx].openPorts.insert(port)
        } else {
            var host = DiscoveredHost(ip: ip, openPorts: [port])
            host.isLocalDevice = (ip == localIP)
            discoveredHosts.append(host)
            discoveredHosts.sort { $0.sortableIP < $1.sortableIP }
        }
    }

    private static func getLocalNetworkInfo() -> (ip: String, mask: String, cidr: Int)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let addr = ptr.pointee
            guard addr.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: addr.ifa_name)
            guard name.hasPrefix("en") else { continue }

            var ip = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr.ifa_addr, socklen_t(addr.ifa_addr.pointee.sa_len),
                        &ip, socklen_t(ip.count), nil, 0, NI_NUMERICHOST)
            let ipStr = String(cString: ip)
            guard !ipStr.isEmpty, !ipStr.hasPrefix("127.") else { continue }

            var mask = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr.ifa_netmask, socklen_t(addr.ifa_netmask.pointee.sa_len),
                        &mask, socklen_t(mask.count), nil, 0, NI_NUMERICHOST)
            let maskStr = String(cString: mask)

            let cidr = maskStr.split(separator: ".").compactMap { UInt8($0) }
                .reduce(0) { $0 + $1.nonzeroBitCount }

            return (ipStr, maskStr, cidr)
        }
        return nil
    }

    private static func subnetIPs(ip: String, mask: String) -> [String] {
        let ipParts = ip.split(separator: ".").compactMap { UInt32($0) }
        let maskParts = mask.split(separator: ".").compactMap { UInt32($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return [] }

        let ipInt = (ipParts[0] << 24) | (ipParts[1] << 16) | (ipParts[2] << 8) | ipParts[3]
        let maskInt = (maskParts[0] << 24) | (maskParts[1] << 16) | (maskParts[2] << 8) | maskParts[3]

        let network = ipInt & maskInt
        let broadcast = network | ~maskInt

        guard broadcast - network < 1024 else { return [] }

        var ips: [String] = []
        for addr in (network + 1)..<broadcast {
            ips.append("\(addr >> 24 & 0xFF).\(addr >> 16 & 0xFF).\(addr >> 8 & 0xFF).\(addr & 0xFF)")
        }
        return ips
    }

    private func resolveHostname(_ ip: String) async -> String? {
        await withCheckedContinuation { continuation in
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            inet_pton(AF_INET, ip, &addr.sin_addr)

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = withUnsafePointer(to: &addr, {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    getnameinfo(ptr, socklen_t(MemoryLayout<sockaddr_in>.size),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, 0)
                }
            })

            if result == 0 {
                let name = String(cString: hostname)
                if name != ip { continuation.resume(returning: name) }
                else { continuation.resume(returning: nil) }
            } else {
                continuation.resume(returning: nil)
            }
        }
    }

    nonisolated private func startBonjourDiscovery() {
        let serviceTypes = [
            "_ssh._tcp", "_http._tcp", "_smb._tcp",
            "_rfb._tcp", "_airplay._tcp", "_ipp._tcp",
            "_companion-link._tcp"
        ]

        let serviceLabels: [String: String] = [
            "_ssh._tcp": "SSH", "_http._tcp": "HTTP", "_smb._tcp": "SMB",
            "_rfb._tcp": "VNC", "_airplay._tcp": "AirPlay", "_ipp._tcp": "Printer",
            "_companion-link._tcp": "Apple"
        ]

        for type in serviceTypes {
            let params = NWParameters()
            params.includePeerToPeer = true
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: params)
            browser.browseResultsChangedHandler = { results, _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    for result in results {
                        if case .service(let name, let svcType, _, _) = result.endpoint {
                            let label = serviceLabels[svcType] ?? svcType
                            let svcTag = "\(label): \(name)"
                            for i in self.discoveredHosts.indices {
                                if !self.discoveredHosts[i].services.contains(svcTag) {
                                    let host = self.discoveredHosts[i]
                                    let relevantPort = self.bonjourPort(for: svcType)
                                    if host.openPorts.contains(relevantPort) {
                                        self.discoveredHosts[i].services.append(svcTag)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            browser.start(queue: .global())
            Task { @MainActor in
                bonjourBrowsers.append(browser)
            }
        }
    }

    nonisolated private func bonjourPort(for serviceType: String) -> Int {
        switch serviceType {
        case "_ssh._tcp": return 22
        case "_http._tcp": return 80
        case "_smb._tcp": return 445
        case "_rfb._tcp": return 5900
        case "_airplay._tcp": return 7000
        case "_ipp._tcp": return 631
        case "_companion-link._tcp": return 62078
        default: return 0
        }
    }

    private static let pathPrefix = "export PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"; "

    private func buildCommand(target: String) -> String {
        let safeTarget = target.replacingOccurrences(of: "'", with: "'\\''")
        let prefix = Self.pathPrefix
        switch selectedTool {
        case .ping:
            return "\(prefix)stdbuf -oL ping -c \(pingCount) '\(safeTarget)' 2>&1"
        case .traceroute:
            return "\(prefix)stdbuf -oL traceroute -m \(tracerouteMaxHops) '\(safeTarget)' 2>&1 || stdbuf -oL tracepath '\(safeTarget)' 2>&1"
        case .dnsLookup:
            return "\(prefix)dig '\(safeTarget)' \(dnsRecordType) +noall +answer +authority +stats 2>&1 || nslookup -type=\(dnsRecordType) '\(safeTarget)' 2>&1 || host -t \(dnsRecordType) '\(safeTarget)' 2>&1"
        case .portCheck:
            return "\(prefix)nc -zv -w \(portCheckTimeout) '\(safeTarget)' \(portCheckPortValue) 2>&1"
        case .iperfDownload:
            let parallel = iperfStreams > 1 ? " -P \(iperfStreams)" : ""
            return "\(prefix)iperf3 -c '\(safeTarget)' -p \(iperfPort) -t \(iperfDuration) -R\(parallel) --forceflush 2>&1"
        case .iperfUpload:
            let parallel = iperfStreams > 1 ? " -P \(iperfStreams)" : ""
            return "\(prefix)iperf3 -c '\(safeTarget)' -p \(iperfPort) -t \(iperfDuration)\(parallel) --forceflush 2>&1"
        case .lanScan:
            return ""
        }
    }
}

struct ToolsView: View {
    @Environment(ServerStore.self) private var store
    @State private var viewModel = ToolsViewModel()
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Run target picker
                    StatCard(title: "Run From", icon: "server.rack", color: .blue) {
                        Picker("Run From", selection: $viewModel.selectedTarget) {
                            Label("This Mac", systemImage: "desktopcomputer")
                                .tag(RunTarget.local as RunTarget?)
                            if !store.servers.isEmpty {
                                Divider()
                                ForEach(store.servers) { server in
                                    Text(server.name)
                                        .tag(RunTarget.remote(server) as RunTarget?)
                                }
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    // Tool picker
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Tool", systemImage: "wrench.and.screwdriver")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.indigo)
                            .padding(.horizontal)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(availableTools) { tool in
                                    ToolChip(
                                        tool: tool,
                                        isSelected: viewModel.selectedTool == tool
                                    ) {
                                        viewModel.selectedTool = tool
                                    }
                                }
                            }
                            .padding(.horizontal)
                        }

                        Text(viewModel.selectedTool.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    }
                    .padding(.vertical)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

                    // Target & options (hidden for LAN Scan)
                    if viewModel.selectedTool.needsTarget {
                        StatCard(title: "Configuration", icon: "slider.horizontal.3", color: .orange) {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Target Host / IP")
                                        .font(.caption.bold())
                                        .foregroundStyle(.secondary)
                                    TextField(viewModel.selectedTool.targetPlaceholder, text: $viewModel.targetHost)
                                        .textFieldStyle(.roundedBorder)
                                        .autocorrectionDisabled()
                                        .focused($isTextFieldFocused)
                                        .submitLabel(.done)
                                        .onSubmit { isTextFieldFocused = false }

                                    if !viewModel.hostHistory.isEmpty {
                                        ScrollView(.horizontal, showsIndicators: false) {
                                            HStack(spacing: 6) {
                                                ForEach(viewModel.hostHistory, id: \.self) { host in
                                                    Button {
                                                        viewModel.targetHost = host
                                                    } label: {
                                                        Text(host)
                                                            .font(.caption2)
                                                            .padding(.horizontal, 8)
                                                            .padding(.vertical, 4)
                                                            .background(
                                                                viewModel.targetHost == host
                                                                    ? Color.orange
                                                                    : Color.secondary.opacity(0.15)
                                                            )
                                                            .foregroundStyle(
                                                                viewModel.targetHost == host
                                                                    ? .white
                                                                    : .primary
                                                            )
                                                            .clipShape(Capsule())
                                                    }
                                                    .buttonStyle(.plain)
                                                    .contextMenu {
                                                        Button(role: .destructive) {
                                                            viewModel.removeFromHistory(host)
                                                        } label: {
                                                            Label("Remove", systemImage: "trash")
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                toolOptions
                            }
                        }
                    }

                    // Run / Stop button
                    if viewModel.isRunning {
                        if viewModel.selectedTool == .lanScan {
                            VStack(spacing: 8) {
                                ProgressView(value: viewModel.scanProgress) {
                                    HStack {
                                        Text("Scanning…")
                                            .font(.caption.weight(.semibold))
                                        Spacer()
                                        Text("\(viewModel.discoveredHosts.count) found")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .tint(.indigo)

                                Button(role: .destructive) {
                                    viewModel.stop()
                                } label: {
                                    HStack {
                                        Image(systemName: "stop.fill")
                                        Text("Stop Scan")
                                            .fontWeight(.semibold)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                }
                                .buttonStyle(.borderedProminent)
                            }
                        } else {
                            Button(role: .destructive) {
                                viewModel.stop()
                            } label: {
                                HStack {
                                    Image(systemName: "stop.fill")
                                    Text("Stop")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    } else {
                        Button {
                            viewModel.run()
                        } label: {
                            HStack {
                                Image(systemName: viewModel.selectedTool.icon)
                                Text(viewModel.selectedTool == .lanScan ? "Scan Network" : "Run \(viewModel.selectedTool.rawValue)")
                                    .fontWeight(.semibold)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.selectedTarget == nil)
                    }

                    // Scan results
                    if !viewModel.discoveredHosts.isEmpty {
                        StatCard(title: "Devices (\(viewModel.discoveredHosts.count))", icon: "network", color: .cyan) {
                            VStack(spacing: 0) {
                                ForEach(viewModel.discoveredHosts) { host in
                                    DiscoveredHostRow(host: host)
                                    if host.id != viewModel.discoveredHosts.last?.id {
                                        Divider().padding(.leading, 40)
                                    }
                                }
                            }
                        }
                    }

                    // Throughput chart
                    if viewModel.throughputSamples.count >= 2 {
                        IperfChartView(samples: viewModel.throughputSamples)
                    }

                    // Output
                    if !viewModel.output.isEmpty {
                        StatCard(title: "Output", icon: "terminal", color: .green) {
                            ScrollView(.horizontal) {
                                Text(viewModel.output)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image(systemName: "wrench.and.screwdriver")
                            .foregroundStyle(.indigo)
                        Text("Tools")
                    }
                    .font(.title3.weight(.semibold))
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .onChange(of: viewModel.selectedTarget) {
                if !availableTools.contains(viewModel.selectedTool) {
                    viewModel.selectedTool = availableTools.first ?? .ping
                }
            }
        }
    }

    private var isLocal: Bool {
        viewModel.selectedTarget == .local
    }

    private var availableTools: [NetworkTool] {
        if isLocal {
            return NetworkTool.allCases.filter(\.availableLocally)
        }
        return NetworkTool.allCases.filter { $0 != .lanScan }
    }

    @ViewBuilder
    private var toolOptions: some View {
        switch viewModel.selectedTool {
        case .ping:
            HStack {
                Text("Ping Count")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Count", selection: $viewModel.pingCount) {
                    ForEach([5, 10, 20, 50, 100], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

        case .traceroute:
            HStack {
                Text("Max Hops")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Max Hops", selection: $viewModel.tracerouteMaxHops) {
                    ForEach([15, 30, 50, 64], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

        case .dnsLookup:
            HStack {
                Text("Record Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Type", selection: $viewModel.dnsRecordType) {
                    ForEach(["A", "AAAA", "MX", "NS", "TXT", "CNAME", "SOA", "PTR", "SRV", "ANY"], id: \.self) { type in
                        Text(type).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

        case .portCheck:
            HStack {
                Text("Port")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("443", text: $viewModel.portCheckPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
            HStack {
                Text("Timeout (seconds)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Timeout", selection: $viewModel.portCheckTimeout) {
                    ForEach([3, 5, 10, 15], id: \.self) { n in
                        Text("\(n)s").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }

        case .iperfDownload, .iperfUpload:
            iperfOptions

        case .lanScan:
            EmptyView()
        }
    }

    private var iperfOptions: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Duration (seconds)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Duration", selection: $viewModel.iperfDuration) {
                    ForEach([5, 10, 20, 30, 60], id: \.self) { n in
                        Text("\(n)s").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            HStack {
                Text("Parallel Streams")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Streams", selection: $viewModel.iperfStreams) {
                    ForEach([1, 2, 4, 6, 8, 10], id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            HStack {
                Text("Port")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                TextField("5201", text: $viewModel.iperfPortText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

// MARK: - Discovered Host Row

struct DiscoveredHostRow: View {
    let host: DiscoveredHost

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: host.deviceIcon)
                .font(.title3)
                .foregroundStyle(.cyan)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(host.ip)
                        .font(.subheadline.weight(.semibold))
                        .textSelection(.enabled)
                    if host.isLocalDevice {
                        Text("(this device)")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue, in: Capsule())
                    }
                }

                if let hostname = host.hostname {
                    Text(hostname)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                FlowLayout(spacing: 4) {
                    ForEach(host.openPorts.sorted(), id: \.self) { port in
                        Text(DiscoveredHost.portLabels[port] ?? "\(port)")
                            .font(.system(.caption2, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.cyan.opacity(0.15))
                            .foregroundStyle(.cyan)
                            .clipShape(Capsule())
                    }
                }

                if !host.services.isEmpty {
                    ForEach(host.services, id: \.self) { service in
                        Label(service, systemImage: "bonjour")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Flow Layout

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(proposal: proposal, subviews: subviews)
        for (index, origin) in result.origins.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), origins)
    }
}

// MARK: - Tool Chip

struct ToolChip: View {
    let tool: NetworkTool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(tool.rawValue, systemImage: tool.icon)
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.indigo : Color.secondary.opacity(0.12))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - iPerf Throughput Chart

struct IperfChartView: View {
    let samples: [ThroughputSample]

    private var normalizedSamples: [(time: Double, mbps: Double)] {
        let baseTime = samples.first?.time ?? 0
        return samples.map { (time: $0.time - baseTime, mbps: $0.mbps) }
    }

    private var peakMbps: Double {
        samples.map(\.mbps).max() ?? 0
    }

    private var avgMbps: Double {
        guard !samples.isEmpty else { return 0 }
        return samples.map(\.mbps).reduce(0, +) / Double(samples.count)
    }

    private func formatThroughput(_ mbps: Double) -> String {
        if mbps >= 1000 {
            return String(format: "%.2f Gbps", mbps / 1000)
        } else {
            return String(format: "%.1f Mbps", mbps)
        }
    }

    var body: some View {
        StatCard(title: "Throughput", icon: "chart.xyaxis.line", color: .indigo) {
            VStack(alignment: .leading, spacing: 8) {
                let data = normalizedSamples
                Chart(Array(data.enumerated()), id: \.offset) { _, point in
                    AreaMark(
                        x: .value("Time", point.time),
                        y: .value("Mbps", point.mbps)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.indigo.opacity(0.3), .indigo.opacity(0.05)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Mbps", point.mbps)
                    )
                    .foregroundStyle(.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                    .interpolationMethod(.catmullRom)
                }
                .chartXAxisLabel("Time (s)")
                .chartYAxisLabel("Throughput")
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(dash: [4, 4]))
                            .foregroundStyle(.secondary.opacity(0.3))
                        AxisValueLabel {
                            if let mbps = value.as(Double.self) {
                                Text(formatThroughput(mbps))
                                    .font(.system(.caption2, design: .monospaced))
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisGridLine(stroke: StrokeStyle(dash: [4, 4]))
                            .foregroundStyle(.secondary.opacity(0.3))
                        AxisValueLabel {
                            if let t = value.as(Double.self) {
                                Text(verbatim: "\(Int(t))s")
                                    .font(.system(.caption2, design: .monospaced))
                            }
                        }
                    }
                }
                .frame(height: 200)

                HStack(spacing: 16) {
                    Label {
                        Text("Peak: \(formatThroughput(peakMbps))")
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Label {
                        Text("Avg: \(formatThroughput(avgMbps))")
                            .font(.caption.weight(.semibold))
                    } icon: {
                        Image(systemName: "equal.circle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.top, 4)
            }
        }
    }
}
