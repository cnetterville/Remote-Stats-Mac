//
//  Models.swift
//  Remote Stats Mac
//

import Foundation

enum ServerPlatform: String, Codable, CaseIterable, Sendable {
    case unix = "unix"
    case windows = "windows"

    var displayName: String {
        switch self {
        case .unix: return "Linux / macOS"
        case .windows: return "Windows"
        }
    }
}

enum AuthMethod: String, Codable, CaseIterable, Sendable {
    case password = "password"
    case privateKey = "privateKey"

    var displayName: String {
        switch self {
        case .password: return "Password"
        case .privateKey: return "Private Key"
        }
    }
}

struct ServerConfig: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 22
    var username: String
    var password: String
    var authMethod: AuthMethod = .password
    var privateKey: String = ""
    var timeout: Int = 30
    var tag: String = ""
    var platform: ServerPlatform = .unix

    init(id: UUID = UUID(), name: String, host: String, port: Int = 22,
         username: String, password: String, authMethod: AuthMethod = .password,
         privateKey: String = "", timeout: Int = 30, tag: String = "",
         platform: ServerPlatform = .unix) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.authMethod = authMethod
        self.privateKey = privateKey
        self.timeout = timeout
        self.tag = tag
        self.platform = platform
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, username, password, authMethod, privateKey, timeout, tag, platform
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(username, forKey: .username)
        try c.encode(timeout, forKey: .timeout)
        if authMethod != .password { try c.encode(authMethod, forKey: .authMethod) }
        if !tag.isEmpty { try c.encode(tag, forKey: .tag) }
        if platform != .unix { try c.encode(platform, forKey: .platform) }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 22
        username = try c.decode(String.self, forKey: .username)
        password = (try? c.decode(String.self, forKey: .password)) ?? ""
        authMethod = (try? c.decode(AuthMethod.self, forKey: .authMethod)) ?? .password
        privateKey = (try? c.decode(String.self, forKey: .privateKey)) ?? ""
        timeout = (try? c.decode(Int.self, forKey: .timeout)) ?? 30
        tag = (try? c.decode(String.self, forKey: .tag)) ?? ""
        platform = (try? c.decode(ServerPlatform.self, forKey: .platform)) ?? .unix
    }
}

struct CachedNetworkInfo: Codable, Sendable {
    var externalIP: String = ""
    var isp: String = ""
    var location: String = ""
    var lastFetched: Date = .distantPast

    var isFresh: Bool {
        Date().timeIntervalSince(lastFetched) < 86400
    }
}

struct CachedUpdateInfo: Codable, Sendable {
    var count: Int
    var lastFetched: Date = .distantPast

    var isFresh: Bool {
        Date().timeIntervalSince(lastFetched) < 21600
    }
}

struct ServerStats: Sendable {
    var uptime: String = "--"
    var memory: MemoryStats = MemoryStats()
    var load: LoadStats = LoadStats()
    var temperatureCelsius: Double? = nil
    var bootTime: String = "--"
    var osVersion: String = "--"
    var pendingUpdates: Int? = nil
    var logins: [LoginEntry] = []
    var cpuModel: String = "--"
    var cpuCores: Int = 0
    var cpuCoreDetails: String = ""
    var machineModel: String = ""
    var disks: [MountPoint] = []
    var processes: [ProcessEntry] = []
    var memoryProcesses: [ProcessEntry] = []
    var dockerContainers: [DockerContainer] = []
    var proxmoxGuests: [ProxmoxGuest] = []
    var proxmoxStorage: [ProxmoxStorage] = []
    var internalIP: String = ""
    var hostname: String = ""
    var gateway: String = ""
    var networkInterface: String = ""
    var linkSpeed: String = ""
    var macAddress: String = ""
    var dnsServers: String = ""
    var rxBytes: Int64 = 0
    var txBytes: Int64 = 0
    var externalIP: String = ""
    var isp: String = ""
    var location: String = ""
    var latencyMs: Double? = nil
    var powerWatts: Double? = nil
    var piThrottleFlags: UInt32? = nil
}

struct DockerContainer: Identifiable, Sendable {
    var id: String
    var name: String
    var image: String
    var status: String
    var state: String
    var ports: String
    var composeProject: String = ""
    var composeService: String = ""
    var updateAvailable: Bool = false

    var isRunning: Bool { state.lowercased() == "running" }
}

struct ProxmoxGuest: Identifiable, Sendable {
    var id: String
    var type: String
    var name: String
    var status: String
    var memoryMB: Int
    var memUsedMB: Int
    var diskGB: Double
    var uptimeSeconds: Int
    var cpuUsage: Double
    var cpuCount: Int
    var node: String
    var ipAddress: String = ""

    var isRunning: Bool { status.lowercased() == "running" }
    var typeLabel: String { type == "lxc" ? "LXC" : "VM" }

    var memoryPercent: Double {
        guard memoryMB > 0 else { return 0 }
        return Double(memUsedMB) / Double(memoryMB)
    }

    var formattedUptime: String? {
        guard uptimeSeconds > 0 else { return nil }
        let d = uptimeSeconds / 86400
        let h = (uptimeSeconds % 86400) / 3600
        let m = (uptimeSeconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

struct ProxmoxStorage: Identifiable, Sendable {
    var id: String { "\(node)/\(storage)" }
    var storage: String
    var node: String
    var type: String
    var totalBytes: Int64
    var usedBytes: Int64
    var status: String

    var isActive: Bool { status == "available" }
    var usedPercent: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(usedBytes) / Double(totalBytes)
    }
    var totalGB: Double { Double(totalBytes) / 1_073_741_824 }
    var usedGB: Double { Double(usedBytes) / 1_073_741_824 }
    var freeGB: Double { Double(totalBytes - usedBytes) / 1_073_741_824 }

    var formattedTotal: String { formatSize(totalBytes) }
    var formattedUsed: String { formatSize(usedBytes) }
    var formattedFree: String { formatSize(totalBytes - usedBytes) }

    private func formatSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1024 { return String(format: "%.1f TB", gb / 1024) }
        return String(format: "%.1f GB", gb)
    }
}

struct ProxmoxBackup: Identifiable, Sendable {
    var id: String { volid }
    var volid: String
    var storage: String
    var size: Int64
    var date: Date?
    var format: String
    var vmid: Int
    var notes: String

    var formattedSize: String {
        let gb = Double(size) / 1_073_741_824
        if gb >= 1.0 { return String(format: "%.1f GB", gb) }
        return String(format: "%.0f MB", Double(size) / 1_048_576)
    }

    var formattedDate: String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

struct ProxmoxSnapshot: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var description: String
    var date: Date?
    var parent: String

    var formattedDate: String {
        guard let date else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

struct ProxmoxTask: Identifiable, Sendable {
    var id: String { upid }
    var upid: String
    var type: String
    var status: String
    var startTime: Date?
    var endTime: Date?
    var node: String
    var user: String

    var isOK: Bool { status == "OK" || status.isEmpty }

    var formattedStart: String {
        guard let startTime else { return "" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: startTime)
    }

    var duration: String? {
        guard let s = startTime, let e = endTime else { return nil }
        let secs = Int(e.timeIntervalSince(s))
        if secs < 60 { return "\(secs)s" }
        return "\(secs / 60)m \(secs % 60)s"
    }
}

struct ProxmoxNetworkInterface: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var hwaddr: String
    var bridge: String
    var model: String
    var firewall: Bool
    var tag: Int?
}

struct ProxmoxGuestConfig: Sendable {
    var cores: Int
    var sockets: Int
    var memoryMB: Int
    var osType: String
    var networkInterfaces: [ProxmoxNetworkInterface]
    var description: String
}

struct ProcessEntry: Identifiable, Sendable {
    var id = UUID()
    var pid: String
    var user: String
    var cpu: Double
    var mem: Double
    var command: String

    var displayName: String {
        let exec = command.components(separatedBy: " ").first ?? command
        let name = exec.components(separatedBy: "/").last ?? exec
        return String(name.prefix(22))
    }
}

struct MountPoint: Identifiable, Sendable {
    var id: String { mountPath }
    var mountPath: String
    var totalGB: Double = 0
    var usedGB: Double = 0
    var freeGB: Double = 0
    var usedPercent: Double = 0

    var totalFormatted: String { formatGB(totalGB) }
    var usedFormatted:  String { formatGB(usedGB)  }
    var freeFormatted:  String { formatGB(freeGB)  }

    private func formatGB(_ gb: Double) -> String {
        guard gb > 0 else { return "--" }
        return gb >= 1.0 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", gb * 1024)
    }
}

struct DiskStats: Sendable {
    var totalGB: Double = 0
    var usedGB: Double = 0
    var freeGB: Double = 0
    var usedPercent: Double = 0

    var totalFormatted: String { formatGB(totalGB) }
    var usedFormatted:  String { formatGB(usedGB)  }
    var freeFormatted:  String { formatGB(freeGB)  }

    private func formatGB(_ gb: Double) -> String {
        guard gb > 0 else { return "--" }
        return gb >= 1.0 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", gb * 1024)
    }
}

struct MemoryStats: Sendable {
    var totalMB: Int = 0
    var usedMB: Int = 0
    var freeMB: Int = 0
    var usedPercent: Double = 0
    var swapTotalMB: Int = 0
    var swapUsedMB: Int = 0
    var swapFreeMB: Int = 0
    var swapPercent: Double = 0

    var totalFormatted: String { formatMB(totalMB) }
    var usedFormatted: String { formatMB(usedMB) }
    var freeFormatted: String { formatMB(freeMB) }
    var swapTotalFormatted: String { formatMB(swapTotalMB) }
    var swapUsedFormatted: String { formatMB(swapUsedMB) }
    var swapFreeFormatted: String { formatMB(swapFreeMB) }

    var hasSwap: Bool { swapTotalMB > 0 }

    private func formatMB(_ mb: Int) -> String {
        guard mb > 0 else { return "--" }
        return mb >= 1024 ? String(format: "%.1f GB", Double(mb) / 1024.0) : "\(mb) MB"
    }
}

struct LoadStats: Sendable {
    var oneMin: String = "--"
    var fiveMin: String = "--"
    var fifteenMin: String = "--"
}

struct LoginEntry: Identifiable, Sendable {
    var id = UUID()
    var user: String
    var terminal: String
    var from: String
    var dateString: String
    var isActive: Bool
}

struct LiveStats: Sendable {
    var uptime: String = "--"
    var memory: MemoryStats = MemoryStats()
    var load: LoadStats = LoadStats()
    var temperatureCelsius: Double? = nil
    var processes: [ProcessEntry] = []
    var memoryProcesses: [ProcessEntry] = []
    var rxBytes: Int64 = 0
    var txBytes: Int64 = 0
}

enum SSHError: Error, LocalizedError, Sendable {
    case timeout
    case authenticationFailed
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout: return "Connection timed out. Check host, port, and timeout setting."
        case .authenticationFailed: return "Authentication failed. Check username and password."
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        }
    }
}

// MARK: - NUT UPS Models

struct NUTConfig: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var host: String
    var port: Int = 3493
    var upsName: String
    var username: String = ""
    var password: String = ""

    init(id: UUID = UUID(), name: String, host: String, port: Int = 3493,
         upsName: String, username: String = "", password: String = "") {
        self.id       = id
        self.name     = name
        self.host     = host
        self.port     = port
        self.upsName  = upsName
        self.username = username
        self.password = password
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, host, port, upsName, username, password
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(host, forKey: .host)
        try c.encode(port, forKey: .port)
        try c.encode(upsName, forKey: .upsName)
        try c.encode(username, forKey: .username)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        host = try c.decode(String.self, forKey: .host)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 3493
        upsName = try c.decode(String.self, forKey: .upsName)
        username = (try? c.decode(String.self, forKey: .username)) ?? ""
        password = (try? c.decode(String.self, forKey: .password)) ?? ""
    }
}

struct UPSStats: Sendable {
    nonisolated init() {}

    var rawStatus: String = ""
    var batteryCharge: Double? = nil
    var batteryRuntime: Int? = nil
    var batteryVoltage: Double? = nil
    var batteryVoltageNominal: Double? = nil
    var load: Double? = nil
    var inputVoltage: Double? = nil
    var inputVoltageNominal: Double? = nil
    var outputVoltage: Double? = nil
    var model: String = ""
    var manufacturer: String = ""
    var nominalPower: Int? = nil

    var statusFlags: Set<UPSStatusFlag> {
        Set(rawStatus.components(separatedBy: " ").compactMap { UPSStatusFlag(rawValue: $0) })
    }

    var isOnline: Bool { statusFlags.contains(.onLine) }

    var primaryFlag: UPSStatusFlag? { UPSStats.primaryFlag(from: rawStatus) }

    static func primaryFlag(from rawStatus: String) -> UPSStatusFlag? {
        let flags = Set(rawStatus.components(separatedBy: " ").compactMap { UPSStatusFlag(rawValue: $0) })
        if flags.contains(.forcedShutdown)                              { return .forcedShutdown }
        if flags.contains(.onBattery) && flags.contains(.lowBattery)   { return .lowBattery }
        if flags.contains(.onBattery)                                   { return .onBattery }
        if flags.contains(.overloaded)                                  { return .overloaded }
        if flags.contains(.replaceBattery)                              { return .replaceBattery }
        if flags.contains(.bypass)                                      { return .bypass }
        if flags.contains(.onLine)                                      { return .onLine }
        if flags.contains(.offline)                                     { return .offline }
        return nil
    }

    var formattedRuntime: String? {
        guard let s = batteryRuntime, s > 0 else { return nil }
        if s >= 3600 { return String(format: "%dh %dm", s / 3600, (s % 3600) / 60) }
        if s >= 60   { return String(format: "%dm %ds", s / 60, s % 60) }
        return "\(s)s"
    }
}

enum UPSStatusFlag: String, Sendable, Hashable {
    case onLine          = "OL"
    case onBattery       = "OB"
    case lowBattery      = "LB"
    case highBattery     = "HB"
    case replaceBattery  = "RB"
    case charging        = "CHRG"
    case discharging     = "DISCHRG"
    case bypass          = "BYPASS"
    case calibrating     = "CAL"
    case offline         = "OFF"
    case overloaded      = "OVER"
    case trimming        = "TRIM"
    case boosting        = "BOOST"
    case forcedShutdown  = "FSD"
}

struct UPSRowStatus: Sendable {
    var isOnline: Bool = false
    var batteryCharge: Double? = nil
    var batteryRuntime: Int? = nil
    var rawStatus: String = ""
    var isChecking: Bool = true
    var lastChecked: Date? = nil
    var error: String? = nil

    var formattedRuntime: String? {
        guard let s = batteryRuntime, s > 0 else { return nil }
        if s >= 3600 { return String(format: "%dh %dm", s / 3600, (s % 3600) / 60) }
        if s >= 60   { return String(format: "%dm", s / 60) }
        return "\(s)s"
    }
}

// MARK: -

enum OSType: Sendable {
    case linux(distro: String)
    case macOS
    case windows
    case unknown

    init(osVersionString: String, hardwareModel: String = "") {
        let s = osVersionString.lowercased()
        let hw = hardwareModel.lowercased()

        if s.contains("windows") || s.contains("microsoft") {
            self = .windows
            return
        }

        if s.contains("macos") || s.contains("mac os") ||
           s.contains("productname") || s.contains("darwin") {
            self = .macOS
            return
        }

        let distroMap: [(keyword: String, id: String)] = [
            ("ubuntu",       "ubuntu"),
            ("raspberry pi", "raspbian"),
            ("raspbian",     "raspbian"),
            ("debian",       "debian"),
            ("fedora",      "fedora"),
            ("arch linux",  "arch"),
            ("alpine",      "alpine"),
            ("centos",      "centos"),
            ("red hat",     "rhel"),
            ("rocky linux", "rocky"),
            ("almalinux",   "almalinux"),
            ("opensuse",    "opensuse"),
            ("kali",        "kali"),
            ("manjaro",     "manjaro"),
            ("gentoo",      "gentoo"),
            ("nixos",       "nixos"),
            ("pop!_os",     "pop"),
            ("linux mint",  "mint"),
        ]
        for entry in distroMap where s.contains(entry.keyword) {
            var distro = entry.id
            if distro != "raspbian" && hw.contains("raspberry pi") {
                distro = "raspbian"
            }
            self = .linux(distro: distro)
            return
        }
        if s.contains("linux") || s.contains("gnu") {
            self = .linux(distro: hw.contains("raspberry pi") ? "raspbian" : "")
            return
        }

        self = .unknown
    }

    var emoji: String {
        switch self {
        case .macOS:
            return "\u{F8FF}"
        case .windows:
            return "\u{1FA9F}"
        case .unknown:
            return "\u{1F5A5}\u{FE0F}"
        case .linux(let distro):
            switch distro {
            case "ubuntu":    return "\u{1F7E0}"
            case "debian":    return "\u{1F300}"
            case "fedora":    return "\u{1F3A9}"
            case "arch":      return "\u{1F3DB}\u{FE0F}"
            case "alpine":    return "\u{1F3D4}\u{FE0F}"
            case "centos":    return "\u{2B55}"
            case "rhel":      return "\u{1F402}"
            case "opensuse":  return "\u{1F98E}"
            case "raspbian":  return "\u{1F353}"
            case "kali":      return "\u{1F409}"
            case "manjaro":   return "\u{1F33F}"
            case "gentoo":    return "\u{1F98B}"
            case "nixos":     return "\u{2744}\u{FE0F}"
            case "rocky":     return "\u{26F0}\u{FE0F}"
            case "almalinux": return "\u{1F499}"
            case "pop":       return "\u{1F680}"
            case "mint":      return "\u{1F331}"
            default:          return "\u{1F427}"
            }
        }
    }
}

extension OSType: Codable {
    private enum CodingKeys: String, CodingKey { case type, distro }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .linux(let distro):
            try c.encode("linux", forKey: .type)
            try c.encode(distro, forKey: .distro)
        case .macOS:
            try c.encode("macOS", forKey: .type)
        case .windows:
            try c.encode("windows", forKey: .type)
        case .unknown:
            try c.encode("unknown", forKey: .type)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "linux":
            self = .linux(distro: (try? c.decode(String.self, forKey: .distro)) ?? "")
        case "macOS":
            self = .macOS
        case "windows":
            self = .windows
        default:
            self = .unknown
        }
    }
}
