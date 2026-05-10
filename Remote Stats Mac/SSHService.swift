//
//  SSHService.swift
//  Remote Stats Mac
//
//  Requires: Citadel package — https://github.com/orlandos-nl/Citadel
//

import Foundation
import Citadel
import NIOCore
import Crypto
import _CryptoExtras

actor SSHConnectionPool {
    static let shared = SSHConnectionPool()
    private var entries: [UUID: (client: SSHClient, lastUsed: Date)] = [:]
    private let maxIdleSeconds: TimeInterval = 120

    func cached(_ id: UUID) -> SSHClient? {
        guard let entry = entries[id] else { return nil }
        if Date().timeIntervalSince(entry.lastUsed) > maxIdleSeconds {
            entries.removeValue(forKey: id)
            Task { try? await entry.client.close() }
            return nil
        }
        entries[id] = (entry.client, Date())
        return entry.client
    }

    func store(_ client: SSHClient, for id: UUID) {
        entries[id] = (client, Date())
    }

    func invalidate(_ id: UUID) {
        if let entry = entries.removeValue(forKey: id) {
            Task { try? await entry.client.close() }
        }
    }

    func closeAll() {
        for (_, entry) in entries {
            Task { try? await entry.client.close() }
        }
        entries.removeAll()
    }
}

struct SSHService {

    // Octal-escaped printf produces ===RSM_SEP=== at runtime without the literal
    // string appearing in the command text — immune to SSH command echo.
    private static let sep = "printf '\\075\\075\\075RSM_SEP\\075\\075\\075\\n'"

    // Base stats commands (sections 0-13). Network section appended dynamically.
    // RAPL energy is sampled at script start (RSM_E1) and end (section 13) — the
    // intervening commands provide the time gap, eliminating a dedicated sleep.
    private static let baseStatsCmd: [String] = [
        "RSM_E1=$(cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null); uptime || true", // 0
        sep,
        "free -m 2>/dev/null || (vm_stat; sysctl hw.memsize) || true",             // 1
        sep,
        "cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg || true",           // 2
        sep,
        "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || (sensors 2>/dev/null | awk '/^(Package|Core 0|Tctl)/{gsub(/[^0-9.]/,\"\",$2); print $2; exit}') || echo N/A",       // 3
        sep,
        "uptime -s 2>/dev/null || sysctl kern.boottime || true",                   // 4
        sep,
        "([ -f /etc/os-release ] && (grep -m1 '^RASPI_VERSION=' /etc/os-release | cut -d'\"' -f2 | grep . || grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d'\"' -f2)) || sw_vers || true", // 5
        sep,
        "last -n 30 2>/dev/null; who 2>/dev/null; true",                           // 6
        sep,
        "(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs | grep . || lscpu 2>/dev/null | grep -m1 'Model name' | cut -d: -f2 | xargs | grep . || true); echo '---'; (nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo '0'); echo '---'; (system_profiler SPHardwareDataType 2>/dev/null || (cat /proc/device-tree/model 2>/dev/null | tr -d '\\0') || true)", // 7
        sep,
        "if [ -d /System/Library ]; then df -kP 2>/dev/null | tail -n +2 | grep -E ' /$| /Volumes/' | grep -v '/Volumes/\\.timemachine/'; echo '===APFS_CONTAINER==='; /usr/sbin/diskutil info / 2>/dev/null | grep 'Container.*Space:' || true; else df -kP 2>/dev/null | grep -vE '^(tmpfs|devtmpfs|overlay|shm|udev|efivarfs|Filesystem)' | grep -v '/snap/' | grep -v '/docker/'; fi", // 8
        sep,
        "PROCS=$(ps aux 2>/dev/null | tail -n +2); echo \"$PROCS\" | sort -k3 -rn | head -5 || true", // 9
        sep,
        "echo \"$PROCS\" | sort -k4 -rn | head -5 || true",                       // 10
        sep,
        "(export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin\"; docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}\\t{{.Label \"com.docker.compose.project\"}}\\t{{.Label \"com.docker.compose.service\"}}' 2>/dev/null) || true", // 11
        sep,
        "(command -v pvesh >/dev/null 2>&1 && echo '===PVE_VM===' && pvesh get /cluster/resources --type vm --output-format json 2>/dev/null && echo '===PVE_STORAGE===' && pvesh get /cluster/resources --type storage --output-format json 2>/dev/null) || true", // 12
        sep,
        "([ -n \"$RSM_E1\" ] && RSM_E2=$(cat /sys/class/powercap/intel-rapl:0/energy_uj 2>/dev/null) && echo \"scale=1; ($RSM_E2-$RSM_E1)/1000000\" | bc) || (ipmitool dcmi power reading 2>/dev/null | awk '/Instantaneous/{print $4}') || (ipmitool sensor list 2>/dev/null | awk -F'|' '/[Ww]att/{gsub(/ /,\"\",$2); print $2; exit}') || echo N/A; echo '===PWR_THROTTLE==='; (vcgencmd get_throttled 2>/dev/null | cut -d= -f2) || echo N/A", // 13
    ]

    // Network info gathered locally — no external calls.
    // Fields separated by --- : internal IP, hostname, gateway, interface + speed + MAC + rx/tx, DNS
    private static let networkLocalInfo = [
        "(hostname -I 2>/dev/null | awk '{print $1}' || ipconfig getifaddr en0 2>/dev/null || true)",
        "echo '---'",
        "(hostname -f 2>/dev/null || hostname 2>/dev/null || true)",
        "echo '---'",
        "(ip route show default 2>/dev/null | awk '/default/{print $3}' || route -n get default 2>/dev/null | awk '/gateway:/{print $2}' || true)",
        "echo '---'",
        // Interface name, speed, MAC, rx bytes, tx bytes — pick the default-route interface
        // Uses printf for fallback values since echo "-" is swallowed by zsh.
        "(DEV=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1); [ -n \"$DEV\" ] && echo \"$DEV\" && (S=$(cat /sys/class/net/$DEV/speed 2>/dev/null | awk '{print $1\" Mbps\"}'); [ -n \"$S\" ] && echo \"$S\" || printf '%s\\n' '-') && (S=$(cat /sys/class/net/$DEV/address 2>/dev/null); [ -n \"$S\" ] && echo \"$S\" || printf '%s\\n' '-') && (cat /sys/class/net/$DEV/statistics/rx_bytes 2>/dev/null || echo 0) && (cat /sys/class/net/$DEV/statistics/tx_bytes 2>/dev/null || echo 0)) || (DEV=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}'); [ -n \"$DEV\" ] && echo \"$DEV\" && (S=$(system_profiler SPEthernetDataType 2>/dev/null | awk -v dev=\"$DEV\" '/BSD Device Name:/{found=($NF==dev)} found && /Maximum Link Speed:/{sub(/.*: /,\"\"); print; exit}'); [ -n \"$S\" ] && echo \"$S\" || printf '%s\\n' '-') && (S=$(ifconfig $DEV 2>/dev/null | awk '/ether/{print $2}'); [ -n \"$S\" ] && echo \"$S\" || printf '%s\\n' '-') && (netstat -ib 2>/dev/null | grep \"$DEV\" | grep Link | head -1 | awk '{print $(NF-4); print $(NF-1)}' || printf '0\\n0\\n')) || true",
        "echo '---'",
        "(grep -m3 '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | paste -sd, - || scutil --dns 2>/dev/null | grep -m3 'nameserver\\[' | awk '{print $3}' | paste -sd, - || true)",
    ].joined(separator: "\n")

    // Without external IP (cached)
    private static let networkCmdLocal = networkLocalInfo

    // With external IP/ISP via ipinfo.io appended
    private static let networkCmdFull = networkLocalInfo + "\necho '---'\n(curl -s --max-time 5 --connect-timeout 3 ipinfo.io/json 2>/dev/null || true)"

    private static func allStatsCmd(skipExternalIP: Bool) -> String {
        (baseStatsCmd + [sep, skipExternalIP ? networkCmdLocal : networkCmdFull]).joined(separator: "\n")
    }

    // Lightweight check for the server list (uptime + OS + hardware model + memory + cores).
    private static let checkStatusCmd: String = [
        "uptime || true",
        sep,
        "([ -f /etc/os-release ] && (grep -m1 '^RASPI_VERSION=' /etc/os-release | cut -d'\"' -f2 | grep . || grep -m1 '^PRETTY_NAME=' /etc/os-release | cut -d'\"' -f2)) || sw_vers || true",
        sep,
        "(cat /proc/device-tree/model 2>/dev/null | tr -d '\\0') || true",
        sep,
        "free -m 2>/dev/null || (vm_stat; sysctl hw.memsize) || true",
        sep,
        "nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 0",
    ].joined(separator: "\n")

    // Even lighter: just uptime + memory + cores (when OS is already known).
    private static let quickCheckCmd: String = [
        "uptime || true",
        sep,
        "free -m 2>/dev/null || (vm_stat; sysctl hw.memsize) || true",
        sep,
        "nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 0",
    ].joined(separator: "\n")

    // MARK: - Full stats fetch

    static func fetchStats(for config: ServerConfig, cachedNetwork: CachedNetworkInfo? = nil, cachedUpdate: CachedUpdateInfo? = nil) async throws -> ServerStats {
        let netCache = cachedNetwork
        let updCache = cachedUpdate
        return try await withThrowingTaskGroup(of: ServerStats.self) { group in
            group.addTask { try await connect(config: config, cachedNetwork: netCache, cachedUpdate: updCache) }
            group.addTask {
                try await Task.sleep(for: .seconds(config.timeout))
                throw SSHError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Lightweight status + uptime + OS check (used by server list)

    // Pass a non-unknown knownOSType to skip the OS detection command entirely —
    // saves a file read and grep on every background refresh.
    static func checkStatus(for config: ServerConfig, knownOSType: OSType? = nil) async -> (isOnline: Bool, uptime: String, osType: OSType, loadAverage: String, memoryPercent: Double, cpuCores: Int, latencyMs: Double?) {
        let hasKnownOS: Bool = {
            guard let os = knownOSType else { return false }
            if case .unknown = os { return false }
            return true
        }()

        let cmd: String
        if config.platform == .windows {
            cmd = windowsCheckStatusScript(includeOS: !hasKnownOS)
        } else {
            cmd = hasKnownOS ? quickCheckCmd : checkStatusCmd
        }
        let statusTimeout = min(config.timeout, 20)

        for attempt in 1...2 {
            do {
                let (raw, ms): (String, Double) = try await withThrowingTaskGroup(of: (String, Double).self) { group in
                    group.addTask {
                        let client = try await connectClient(config: config)
                        let pingStart: ContinuousClock.Instant = .now
                        _ = await safeRun("echo RSM_PING", on: client)
                        let dur = pingStart.duration(to: .now)
                        let latMs = Double(dur.components.attoseconds) / 1e15 + Double(dur.components.seconds) * 1000
                        let output = await safeRun(cmd, on: client)
                        return (output, latMs)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(statusTimeout))
                        throw SSHError.timeout
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }

                let parts = raw.components(separatedBy: "===RSM_SEP===")
                let rawUptime = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let uptime = StatsParser.parseUptime(rawUptime)
                let load = StatsParser.parseLoadFromUptime(rawUptime)

                if hasKnownOS {
                    // quickCheckCmd sections: 0=uptime, 1=memory, 2=cores
                    let rawMem   = parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let rawCores = parts.dropFirst(2).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                    let mem = StatsParser.parseMemory(rawMem)
                    let cores = Int(rawCores) ?? 0
                    return (true, uptime, knownOSType!, load, mem.usedPercent, cores, ms)
                } else {
                    // checkStatusCmd sections: 0=uptime, 1=OS, 2=HW, 3=memory, 4=cores
                    let rawOS    = parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let rawHW    = parts.dropFirst(2).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let rawMem   = parts.dropFirst(3).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let rawCores = parts.dropFirst(4).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
                    let mem = StatsParser.parseMemory(rawMem)
                    let cores = Int(rawCores) ?? 0
                    return (true, StatsParser.parseUptime(rawUptime), OSType(osVersionString: StatsParser.parseOSVersion(rawOS), hardwareModel: rawHW), load, mem.usedPercent, cores, ms)
                }
            } catch {
                await SSHConnectionPool.shared.invalidate(config.id)
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        return (false, "--", knownOSType ?? .unknown, "", 0, 0, nil)
    }

    // MARK: - Docker container actions

    static func dockerAction(_ action: String, container: String, config: ServerConfig) async throws {
        let client = try await connectClient(config: config)
        let cmd = config.platform == .windows
            ? "docker \(action) \(container)"
            : "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin\"; docker \(action) \(container)"
        _ = try await client.executeCommand(cmd)
    }

    static func checkDockerUpdates(containers: [DockerContainer], config: ServerConfig) async -> Set<String> {
        guard let client = try? await connectClient(config: config) else { return [] }
        let pathPrefix = config.platform == .windows ? "" : "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin\"; "
        var updatedIDs: Set<String> = []
        let images = Set(containers.map(\.image))
        for image in images {
            let cmd = "\(pathPrefix)OLD=$(docker image inspect \(image) --format '{{.Id}}' 2>/dev/null); docker pull \(image) >/dev/null 2>&1; NEW=$(docker image inspect \(image) --format '{{.Id}}' 2>/dev/null); [ \"$OLD\" != \"$NEW\" ] && echo UPDATED || echo CURRENT"
            let result = await safeRun(cmd, on: client).trimmingCharacters(in: .whitespacesAndNewlines)
            if result == "UPDATED" {
                for c in containers where c.image == image {
                    updatedIDs.insert(c.id)
                }
            }
        }
        return updatedIDs
    }

    static func dockerComposeRecreate(project: String, service: String? = nil, config: ServerConfig) async throws {
        let client = try await connectClient(config: config)
        let pathPrefix = config.platform == .windows ? "" : "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin\"; "
        let svc = service ?? ""
        _ = try await client.executeCommand("\(pathPrefix)docker compose -p \(project) up -d \(svc) 2>&1")
    }

    static func fetchDockerContainers(config: ServerConfig) async throws -> [DockerContainer] {
        let client = try await connectClient(config: config)
        let cmd = config.platform == .windows
            ? "docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}\\t{{.Label \"com.docker.compose.project\"}}\\t{{.Label \"com.docker.compose.service\"}}'"
            : "export PATH=\"$PATH:/usr/local/bin:/opt/homebrew/bin\"; docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}\\t{{.Label \"com.docker.compose.project\"}}\\t{{.Label \"com.docker.compose.service\"}}'"
        let raw = await safeRun(cmd, on: client)
        return StatsParser.parseDocker(raw)
    }

    // MARK: - Proxmox guest actions

    static func proxmoxAction(_ action: String, guest: ProxmoxGuest, config: ServerConfig) async throws {
        let client = try await connectClient(config: config)
        let tool = guest.type == "lxc" ? "pct" : "qm"
        _ = try await client.executeCommand("\(tool) \(action) \(guest.id)")
    }

    static func fetchProxmoxGuests(config: ServerConfig) async throws -> [ProxmoxGuest] {
        let client = try await connectClient(config: config)
        let cmd = "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null"
        let raw = await safeRun(cmd, on: client)
        return StatsParser.parseProxmox(raw)
    }

    static func fetchProxmoxSnapshots(guest: ProxmoxGuest, config: ServerConfig) async throws -> [ProxmoxSnapshot] {
        let client = try await connectClient(config: config)
        let path = "/nodes/\(guest.node)/\(guest.type)/\(guest.id)/snapshot"
        let raw = await safeRun("pvesh get \(path) --output-format json 2>/dev/null", on: client)
        return StatsParser.parseProxmoxSnapshots(raw)
    }

    static func createProxmoxSnapshot(guest: ProxmoxGuest, name: String, description: String, config: ServerConfig) async throws {
        let client = try await connectClient(config: config)
        let path = "/nodes/\(guest.node)/\(guest.type)/\(guest.id)/snapshot"
        var cmd = "pvesh create \(path) -snapname '\(name)'"
        if !description.isEmpty { cmd += " -description '\(description)'" }
        _ = try await client.executeCommand(cmd)
    }

    static func deleteProxmoxSnapshot(guest: ProxmoxGuest, snapshotName: String, config: ServerConfig) async throws {
        let client = try await connectClient(config: config)
        let path = "/nodes/\(guest.node)/\(guest.type)/\(guest.id)/snapshot/\(snapshotName)"
        _ = try await client.executeCommand("pvesh delete \(path)")
    }

    static func rollbackProxmoxSnapshot(guest: ProxmoxGuest, snapshotName: String, config: ServerConfig) async throws {
        let client = try await connectClient(config: config)
        let path = "/nodes/\(guest.node)/\(guest.type)/\(guest.id)/snapshot/\(snapshotName)/rollback"
        _ = try await client.executeCommand("pvesh create \(path)")
    }

    static func fetchProxmoxBackups(guest: ProxmoxGuest, config: ServerConfig) async throws -> [ProxmoxBackup] {
        let client = try await connectClient(config: config)
        let storagesRaw = await safeRun("pvesh get /nodes/\(guest.node)/storage --content backup --output-format json 2>/dev/null", on: client)
        let storages = StatsParser.parseProxmoxStorageNames(storagesRaw)
        var allBackups: [ProxmoxBackup] = []
        for storage in storages {
            let raw = await safeRun("pvesh get /nodes/\(guest.node)/storage/\(storage)/content --content backup --vmid \(guest.id) --output-format json 2>/dev/null", on: client)
            allBackups.append(contentsOf: StatsParser.parseProxmoxBackups(raw))
        }
        return allBackups.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func createProxmoxBackup(guest: ProxmoxGuest, storage: String, mode: String, compress: String, config: ServerConfig) async throws {
        let client = try await connectClient(config: config)
        _ = try await client.executeCommand("vzdump \(guest.id) --storage \(storage) --mode \(mode) --compress \(compress)")
    }

    static func deleteProxmoxBackup(node: String, volid: String, config: ServerConfig) async throws {
        let client = try await connectClient(config: config)
        let parts = volid.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let storage = String(parts[0])
        _ = try await client.executeCommand("pvesh delete /nodes/\(node)/storage/\(storage)/content/\(volid)")
    }

    static func fetchBackupStorages(node: String, config: ServerConfig) async throws -> [String] {
        let client = try await connectClient(config: config)
        let raw = await safeRun("pvesh get /nodes/\(node)/storage --content backup --output-format json 2>/dev/null", on: client)
        return StatsParser.parseProxmoxStorageNames(raw)
    }

    static func fetchProxmoxTasks(guest: ProxmoxGuest, config: ServerConfig) async throws -> [ProxmoxTask] {
        let client = try await connectClient(config: config)
        let raw = await safeRun("pvesh get /nodes/\(guest.node)/tasks --vmid \(guest.id) --limit 20 --output-format json 2>/dev/null", on: client)
        return StatsParser.parseProxmoxTasks(raw)
    }

    static func fetchProxmoxGuestConfig(guest: ProxmoxGuest, config: ServerConfig) async throws -> ProxmoxGuestConfig {
        let client = try await connectClient(config: config)
        let path = "/nodes/\(guest.node)/\(guest.type)/\(guest.id)/config"
        let raw = await safeRun("pvesh get \(path) --output-format json 2>/dev/null", on: client)
        return StatsParser.parseProxmoxGuestConfig(raw, type: guest.type)
    }

    static func fetchProxmoxGuestIPs(guests: [ProxmoxGuest], config: ServerConfig) async -> [String: String] {
        let running = guests.filter(\.isRunning)
        guard !running.isEmpty else { return [:] }
        guard let client = try? await connectClient(config: config) else { return [:] }
        var ips: [String: String] = [:]
        for guest in running {
            let cmd: String
            if guest.type == "lxc" {
                cmd = "pct exec \(guest.id) -- hostname -I 2>/dev/null | awk '{print $1}'"
            } else {
                cmd = "pvesh get /nodes/\(guest.node)/qemu/\(guest.id)/agent/network-get-interfaces --output-format json 2>/dev/null | grep -oP '\"ip-address\"\\s*:\\s*\"\\K[0-9.]+' | head -1"
            }
            let raw = await safeRun(cmd, on: client).trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty && raw != "N/A" {
                ips[guest.id] = raw
            }
        }
        return ips
    }

    private static func connectClient(config: ServerConfig) async throws -> SSHClient {
        let pool = SSHConnectionPool.shared
        if let existing = await pool.cached(config.id) {
            return existing
        }
        let auth = try authMethod(for: config)
        let newClient = try await SSHClient.connect(
            host: config.host,
            port: config.port,
            authenticationMethod: auth,
            hostKeyValidator: .acceptAnything(),
            reconnect: .never
        )
        await pool.store(newClient, for: config.id)
        return newClient
    }

    // MARK: - Persistent connection for live polling

    static func openConnection(for config: ServerConfig) async throws -> SSHClient {
        let auth = try authMethod(for: config)
        return try await withThrowingTaskGroup(of: SSHClient.self) { group in
            group.addTask {
                try await SSHClient.connect(
                    host: config.host,
                    port: config.port,
                    authenticationMethod: auth,
                    hostKeyValidator: .acceptAnything(),
                    reconnect: .never
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(config.timeout))
                throw SSHError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // Lightweight command: uptime, memory, load, temperature, cpu procs, mem procs, traffic
    private static let liveStatsCmd: String = [
        "uptime || true",                                                          // 0
        sep,
        "free -m 2>/dev/null || (vm_stat; sysctl hw.memsize) || true",             // 1
        sep,
        "cat /proc/loadavg 2>/dev/null || sysctl -n vm.loadavg || true",           // 2
        sep,
        "cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || (sensors 2>/dev/null | awk '/^(Package|Core 0|Tctl)/{gsub(/[^0-9.]/,\"\",$2); print $2; exit}') || echo N/A",       // 3
        sep,
        "PROCS=$(ps aux 2>/dev/null | tail -n +2); echo \"$PROCS\" | sort -k3 -rn | head -5 || true", // 4
        sep,
        "echo \"$PROCS\" | sort -k4 -rn | head -5 || true",                       // 5
        sep,
        "(DEV=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1); [ -n \"$DEV\" ] && cat /sys/class/net/$DEV/statistics/rx_bytes 2>/dev/null && cat /sys/class/net/$DEV/statistics/tx_bytes 2>/dev/null) || (DEV=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}'); [ -n \"$DEV\" ] && netstat -ib 2>/dev/null | grep \"$DEV\" | grep Link | head -1 | awk '{print $(NF-4); print $(NF-1)}') || printf '0\\n0\\n'", // 6
    ].joined(separator: "\n")

    static func fetchLiveStats(on client: SSHClient, platform: ServerPlatform = .unix) async throws -> LiveStats {
        let cmd = platform == .windows ? windowsLiveStatsScript : liveStatsCmd
        let buffer = try await client.executeCommand(cmd)
        let raw = buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        guard !raw.isEmpty else { throw SSHError.connectionFailed("Empty response") }

        let parts = raw.components(separatedBy: "===RSM_SEP===")
        func part(_ i: Int) -> String {
            i < parts.count ? parts[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }

        var live = LiveStats()
        live.uptime = StatsParser.parseUptime(part(0))
        live.memory = StatsParser.parseMemory(part(1))
        live.load = StatsParser.parseLoad(part(2))
        live.temperatureCelsius = StatsParser.parseTemperature(part(3))
        live.processes = StatsParser.parseProcesses(part(4))
        live.memoryProcesses = StatsParser.parseProcesses(part(5))

        let trafficLines = part(6).components(separatedBy: .newlines).filter { !$0.isEmpty }
        if trafficLines.count >= 1 { live.rxBytes = Int64(trafficLines[0]) ?? 0 }
        if trafficLines.count >= 2 { live.txBytes = Int64(trafficLines[1]) ?? 0 }

        return live
    }

    static func closeConnection(_ client: SSHClient) {
        Task { try? await client.close() }
    }

    // MARK: - Pending update count

    private static let unixUpdateCmd = "if command -v apt-get >/dev/null 2>&1; then apt list --upgradable 2>/dev/null | grep upgradable | wc -l; elif command -v dnf >/dev/null 2>&1; then dnf check-update -q 2>/dev/null | grep -E '^[a-zA-Z0-9]' | wc -l; elif command -v yum >/dev/null 2>&1; then yum check-update -q 2>/dev/null | grep -E '^[a-zA-Z0-9]' | wc -l; elif command -v apk >/dev/null 2>&1; then apk version -l '<' 2>/dev/null | grep '<' | wc -l; elif command -v pacman >/dev/null 2>&1; then pacman -Qu 2>/dev/null | wc -l; elif command -v brew >/dev/null 2>&1; then brew outdated -q 2>/dev/null | wc -l; elif command -v softwareupdate >/dev/null 2>&1; then softwareupdate -l 2>/dev/null | grep -c '\\*'; else echo -1; fi"

    private static let windowsUpdateCmd = "try{$s=New-Object -ComObject Microsoft.Update.Session;$r=$s.CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0');Write-Output $r.Updates.Count}catch{Write-Output '-1'};exit 0"

    static func checkForUpdates(config: ServerConfig) async throws -> Int? {
        let client = try await connectClient(config: config)
        return await runUpdateCheck(on: client, platform: config.platform)
    }

    private static func runUpdateCheck(on client: SSHClient, platform: ServerPlatform) async -> Int? {
        let marker = "RSM_UPDATES:"
        let cmd: String
        if platform == .windows {
            cmd = windowsUpdateCmd
        } else {
            cmd = "echo \"\(marker)$(\(unixUpdateCmd))\""
        }
        let raw = await safeRun(cmd, on: client)
        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if platform == .windows {
                if let count = Int(trimmed), count >= 0 { return count }
            } else if trimmed.hasPrefix(marker) {
                let numStr = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                if let count = Int(numStr), count >= 0 { return count }
            }
        }
        return nil
    }

    // MARK: - Windows PowerShell Commands
    // Scripts sent directly via SSH — requires PowerShell as the default SSH shell.
    // All strings use single quotes + concatenation to avoid double-quote conflicts
    // with the shell's command-line parsing.

    private static let winUptime = """
    $ErrorActionPreference='SilentlyContinue'
    $os=Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime,TotalVisibleMemorySize,FreePhysicalMemory,Caption
    $proc=Get-CimInstance Win32_Processor -Property LoadPercentage,NumberOfLogicalProcessors,Name|Select-Object -First 1
    $up=(Get-Date)-$os.LastBootUpTime
    $cpuPct=if($proc.LoadPercentage){$proc.LoadPercentage}else{0}
    $cores=$proc.NumberOfLogicalProcessors
    $loadEq=[math]::Round($cpuPct/100*$cores,2)
    $upStr=''
    if($up.Days -gt 0){$upStr=[string]$up.Days+' days, '}
    $upStr+=[string]$up.Hours+':'+$up.Minutes.ToString('00')
    Write-Output (' up '+$upStr+', 0 users, load average: '+$loadEq+', '+$loadEq+', '+$loadEq)
    """

    // Skips Caption and CPU Name — only queries what live stats and quick checks need.
    private static let winLightPreamble = """
    $ErrorActionPreference='SilentlyContinue'
    $mem=Get-CimInstance Win32_OperatingSystem -Property TotalVisibleMemorySize,FreePhysicalMemory,LastBootUpTime
    $cpuPct=(Get-CimInstance Win32_Processor -Property LoadPercentage|Select-Object -First 1).LoadPercentage
    if(-not $cpuPct){$cpuPct=0}
    $cores=[int]$env:NUMBER_OF_PROCESSORS
    $loadEq=[math]::Round($cpuPct/100*$cores,2)
    $up=(Get-Date)-$mem.LastBootUpTime
    $upStr=''
    if($up.Days -gt 0){$upStr=[string]$up.Days+' days, '}
    $upStr+=[string]$up.Hours+':'+$up.Minutes.ToString('00')
    Write-Output(' up '+$upStr+', 0 users, load average: '+$loadEq+', '+$loadEq+', '+$loadEq)
    """

    private static func windowsStatsScript(skipExternalIP: Bool) -> String {
        var script = winUptime + """
        Write-Output '===RSM_SEP==='
        $t=[math]::Round($os.TotalVisibleMemorySize/1024);$f=[math]::Round($os.FreePhysicalMemory/1024);$u=$t-$f
        Write-Output ('Mem: '+$t+' '+$u+' '+$f+' 0 0 0')
        Write-Output '===RSM_SEP==='
        Write-Output ($loadEq,$loadEq,$loadEq -join ' ')
        Write-Output '===RSM_SEP==='
        Write-Output 'N/A'
        Write-Output '===RSM_SEP==='
        Write-Output $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')
        Write-Output '===RSM_SEP==='
        Write-Output $os.Caption
        Write-Output '===RSM_SEP==='
        try{query user 2>$null}catch{}
        Write-Output '===RSM_SEP==='
        Write-Output $proc.Name;Write-Output '---';Write-Output $cores;Write-Output '---'
        Write-Output '===RSM_SEP==='
        Get-CimInstance Win32_LogicalDisk -Property DeviceID,Size,FreeSpace|Where-Object{$_.Size -gt 0}|ForEach-Object{$tK=[math]::Round($_.Size/1024);$fK=[math]::Round($_.FreeSpace/1024);$uK=$tK-$fK;Write-Output($_.DeviceID+' '+$tK+' '+$uK+' '+$fK+' 0% '+$_.DeviceID+'\')}
        Write-Output '===RSM_SEP==='
        $totalKB=$os.TotalVisibleMemorySize
        $allP=@(Get-Process)
        $allP|Sort-Object CPU -Descending|Select-Object -First 5|ForEach-Object{$c=0;try{$el=((Get-Date)-$_.StartTime).TotalSeconds;if($el -gt 0){$c=[math]::Round($_.CPU/$el*100,1)}}catch{};$m=[math]::Round($_.WorkingSet64/($totalKB*1024)*100,1);'SYSTEM '+[string]$_.Id+' '+$c+' '+$m+' 0 0 - - - - '+$_.ProcessName}
        Write-Output '===RSM_SEP==='
        $allP|Sort-Object WorkingSet64 -Descending|Select-Object -First 5|ForEach-Object{$c=0;try{$el=((Get-Date)-$_.StartTime).TotalSeconds;if($el -gt 0){$c=[math]::Round($_.CPU/$el*100,1)}}catch{};$m=[math]::Round($_.WorkingSet64/($totalKB*1024)*100,1);'SYSTEM '+[string]$_.Id+' '+$c+' '+$m+' 0 0 - - - - '+$_.ProcessName}
        Write-Output '===RSM_SEP==='
        try{docker ps -a --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}\\t{{.State}}\\t{{.Ports}}' 2>$null}catch{}
        Write-Output '===RSM_SEP==='
        $adapter=Get-NetAdapter|Where-Object{$_.Status -eq 'Up'}|Select-Object -First 1
        if($adapter){$ipAddr=(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4|Where-Object{$_.PrefixOrigin -ne 'WellKnown'}|Select-Object -First 1).IPAddress;Write-Output $ipAddr}
        Write-Output '---'
        Write-Output $env:COMPUTERNAME
        Write-Output '---'
        if($adapter){$gw=(Get-NetRoute -InterfaceIndex $adapter.InterfaceIndex -DestinationPrefix '0.0.0.0/0'|Select-Object -First 1).NextHop;Write-Output $gw}
        Write-Output '---'
        if($adapter){Write-Output $adapter.Name;Write-Output $adapter.LinkSpeed;Write-Output($adapter.MacAddress -replace '-',':');$st=Get-NetAdapterStatistics -Name $adapter.Name;Write-Output $st.ReceivedBytes;Write-Output $st.SentBytes}
        Write-Output '---'
        if($adapter){$dns=(Get-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4).ServerAddresses -join ',';Write-Output $dns}
        """
        if !skipExternalIP {
            script += "\nWrite-Output '---'\ntry{curl.exe -s --max-time 5 --connect-timeout 3 http://ipinfo.io/json 2>$null}catch{}"
        }
        script += "\nexit 0"
        return script
    }

    private static func windowsCheckStatusScript(includeOS: Bool) -> String {
        if includeOS {
            return winUptime + """
            Write-Output '===RSM_SEP==='
            Write-Output $os.Caption
            Write-Output '===RSM_SEP==='
            Write-Output ''
            Write-Output '===RSM_SEP==='
            $t=[math]::Round($os.TotalVisibleMemorySize/1024);$f=[math]::Round($os.FreePhysicalMemory/1024);$u=$t-$f
            Write-Output ('Mem: '+$t+' '+$u+' '+$f+' 0 0 0')
            Write-Output '===RSM_SEP==='
            Write-Output $cores
            exit 0
            """
        } else {
            return winLightPreamble + """
            Write-Output '===RSM_SEP==='
            $t=[math]::Round($mem.TotalVisibleMemorySize/1024);$f=[math]::Round($mem.FreePhysicalMemory/1024);$u=$t-$f
            Write-Output('Mem: '+$t+' '+$u+' '+$f+' 0 0 0')
            Write-Output '===RSM_SEP==='
            Write-Output $cores
            exit 0
            """
        }
    }

    private static let windowsLiveStatsScript: String = winLightPreamble + """
    Write-Output '===RSM_SEP==='
    $totalKB=$mem.TotalVisibleMemorySize
    $t=[math]::Round($totalKB/1024);$f=[math]::Round($mem.FreePhysicalMemory/1024);$u=$t-$f
    Write-Output('Mem: '+$t+' '+$u+' '+$f+' 0 0 0')
    Write-Output '===RSM_SEP==='
    Write-Output($loadEq,$loadEq,$loadEq -join ' ')
    Write-Output '===RSM_SEP==='
    Write-Output 'N/A'
    Write-Output '===RSM_SEP==='
    $allP=@(Get-Process)
    $allP|Sort-Object CPU -Descending|Select-Object -First 5|ForEach-Object{$c=0;try{$el=((Get-Date)-$_.StartTime).TotalSeconds;if($el -gt 0){$c=[math]::Round($_.CPU/$el*100,1)}}catch{};$m=[math]::Round($_.WorkingSet64/($totalKB*1024)*100,1);'SYSTEM '+[string]$_.Id+' '+$c+' '+$m+' 0 0 - - - - '+$_.ProcessName}
    Write-Output '===RSM_SEP==='
    $allP|Sort-Object WorkingSet64 -Descending|Select-Object -First 5|ForEach-Object{$c=0;try{$el=((Get-Date)-$_.StartTime).TotalSeconds;if($el -gt 0){$c=[math]::Round($_.CPU/$el*100,1)}}catch{};$m=[math]::Round($_.WorkingSet64/($totalKB*1024)*100,1);'SYSTEM '+[string]$_.Id+' '+$c+' '+$m+' 0 0 - - - - '+$_.ProcessName}
    Write-Output '===RSM_SEP==='
    $adapter=Get-NetAdapter|Where-Object{$_.Status -eq 'Up'}|Select-Object -First 1
    if($adapter){$st=Get-NetAdapterStatistics -Name $adapter.Name;Write-Output $st.ReceivedBytes;Write-Output $st.SentBytes}else{Write-Output '0';Write-Output '0'}
    exit 0
    """

    // MARK: - Private helpers

    private static func connect(config: ServerConfig, cachedNetwork: CachedNetworkInfo?, cachedUpdate: CachedUpdateInfo?) async throws -> ServerStats {
        let skipExternal = cachedNetwork?.isFresh == true
        let client = try await connectClient(config: config)

        let pingStart = ContinuousClock.now
        _ = await safeRun("echo RSM_PING", on: client)
        let latency = pingStart.duration(to: .now)
        let latencyMs = Double(latency.components.attoseconds) / 1e15 + Double(latency.components.seconds) * 1000

        let cmd: String
        if config.platform == .windows {
            cmd = windowsStatsScript(skipExternalIP: skipExternal)
        } else {
            cmd = allStatsCmd(skipExternalIP: skipExternal)
        }
        let raw   = await safeRun(cmd, on: client)
        let parts = raw.components(separatedBy: "===RSM_SEP===")

        func part(_ i: Int) -> String {
            i < parts.count ? parts[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }

        var stats = StatsParser.parse(
            uptimeRaw:      part(0),
            memoryRaw:      part(1),
            loadRaw:        part(2),
            temperatureRaw: part(3),
            bootTimeRaw:    part(4),
            osVersionRaw:   part(5),
            loginsRaw:      part(6),
            cpuRaw:         part(7),
            diskRaw:        part(8),
            processesRaw:   part(9),
            memProcessesRaw: part(10),
            dockerRaw:      part(11),
            proxmoxRaw:     part(12),
            powerRaw:       part(13),
            networkRaw:     part(14)
        )

        if skipExternal, let cached = cachedNetwork {
            stats.externalIP = cached.externalIP
            stats.isp = cached.isp
            stats.location = cached.location
        }

        if let cached = cachedUpdate, cached.isFresh {
            stats.pendingUpdates = cached.count
        } else {
            stats.pendingUpdates = await runUpdateCheck(on: client, platform: config.platform)
        }

        let running = stats.proxmoxGuests.filter(\.isRunning)
        if !running.isEmpty {
            for i in stats.proxmoxGuests.indices where stats.proxmoxGuests[i].isRunning {
                let guest = stats.proxmoxGuests[i]
                let ipCmd: String
                if guest.type == "lxc" {
                    ipCmd = "pct exec \(guest.id) -- hostname -I 2>/dev/null | awk '{print $1}'"
                } else {
                    ipCmd = "pvesh get /nodes/\(guest.node)/qemu/\(guest.id)/agent/network-get-interfaces --output-format json 2>/dev/null | grep -oP '\"ip-address\"\\s*:\\s*\"\\K[0-9.]+' | head -1"
                }
                let ip = await safeRun(ipCmd, on: client).trimmingCharacters(in: .whitespacesAndNewlines)
                if !ip.isEmpty && ip != "N/A" {
                    stats.proxmoxGuests[i].ipAddress = ip
                }
            }
        }

        stats.latencyMs = latencyMs

        return stats
    }

    private static func safeRun(_ command: String, on client: SSHClient) async -> String {
        do {
            let buffer = try await client.executeCommand(command)
            return buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes) ?? ""
        } catch {
            return ""
        }
    }

    // MARK: - Auth method builder

    static func authMethod(for config: ServerConfig) throws -> SSHAuthenticationMethod {
        switch config.authMethod {
        case .password:
            return .passwordBased(username: config.username, password: config.password)
        case .privateKey:
            let pem = config.privateKey
            guard !pem.isEmpty else {
                throw SSHError.authenticationFailed
            }
            return try SSHKeyParser.buildAuthMethod(username: config.username, pemString: pem)
        }
    }
}

// MARK: - SSH Key Parser

struct SSHKeyParser {

    enum KeyError: Error, LocalizedError {
        case unsupportedKeyType
        case invalidKeyData
        case encryptedKeyNotSupported

        var errorDescription: String? {
            switch self {
            case .unsupportedKeyType: return "Unsupported SSH key type. Supported: Ed25519, RSA, ECDSA (P-256/P-384/P-521)."
            case .invalidKeyData: return "Could not parse the private key. Check that it is a valid PEM-encoded key."
            case .encryptedKeyNotSupported: return "Encrypted (passphrase-protected) keys are not supported. Use an unencrypted key."
            }
        }
    }

    static func buildAuthMethod(username: String, pemString: String) throws -> SSHAuthenticationMethod {
        let trimmed = pemString.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.contains("BEGIN OPENSSH PRIVATE KEY") {
            return try parseOpenSSHKey(username: username, pem: trimmed)
        }

        if trimmed.contains("BEGIN RSA PRIVATE KEY") {
            let key = try Insecure.RSA.PrivateKey(sshRsa: trimmed)
            return .rsa(username: username, privateKey: key)
        }

        if trimmed.contains("BEGIN PRIVATE KEY") || trimmed.contains("BEGIN EC PRIVATE KEY") {
            if let method = try? p256Auth(username: username, pem: trimmed) { return method }
            if let method = try? p384Auth(username: username, pem: trimmed) { return method }
            if let method = try? p521Auth(username: username, pem: trimmed) { return method }
            throw KeyError.invalidKeyData
        }

        throw KeyError.unsupportedKeyType
    }

    private static func p256Auth(username: String, pem: String) throws -> SSHAuthenticationMethod {
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        return .p256(username: username, privateKey: key)
    }

    private static func p384Auth(username: String, pem: String) throws -> SSHAuthenticationMethod {
        let key = try P384.Signing.PrivateKey(pemRepresentation: pem)
        return .p384(username: username, privateKey: key)
    }

    private static func p521Auth(username: String, pem: String) throws -> SSHAuthenticationMethod {
        let key = try P521.Signing.PrivateKey(pemRepresentation: pem)
        return .p521(username: username, privateKey: key)
    }

    // MARK: - OpenSSH format parser

    private static func parseOpenSSHKey(username: String, pem: String) throws -> SSHAuthenticationMethod {
        let lines = pem.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") && !$0.isEmpty }
        let base64 = lines.joined()
        guard let data = Data(base64Encoded: base64) else {
            throw KeyError.invalidKeyData
        }

        let magic = "openssh-key-v1\0"
        guard data.count > magic.utf8.count,
              String(data: data[0..<magic.utf8.count], encoding: .utf8) == magic else {
            throw KeyError.invalidKeyData
        }

        var offset = magic.utf8.count

        let cipherName = try readString(from: data, offset: &offset)
        if cipherName != "none" {
            throw KeyError.encryptedKeyNotSupported
        }

        _ = try readString(from: data, offset: &offset) // kdfname
        _ = try readBytes(from: data, offset: &offset)   // kdfoptions
        let numKeys = try readUInt32(from: data, offset: &offset)
        guard numKeys >= 1 else { throw KeyError.invalidKeyData }

        _ = try readBytes(from: data, offset: &offset) // public key blob

        let privateSection = try readBytes(from: data, offset: &offset)
        var pOff = 0
        let check1 = try readUInt32(from: privateSection, offset: &pOff)
        let check2 = try readUInt32(from: privateSection, offset: &pOff)
        guard check1 == check2 else { throw KeyError.invalidKeyData }

        let keyType = try readString(from: privateSection, offset: &pOff)

        switch keyType {
        case "ssh-ed25519":
            _ = try readBytes(from: privateSection, offset: &pOff) // public key
            let privBlob = try readBytes(from: privateSection, offset: &pOff) // 64 bytes: seed + pubkey
            guard privBlob.count >= 32 else { throw KeyError.invalidKeyData }
            let seed = privBlob[0..<32]
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
            return .ed25519(username: username, privateKey: key)

        case "ssh-rsa":
            let key = try Insecure.RSA.PrivateKey(sshRsa: pem)
            return .rsa(username: username, privateKey: key)

        case "ecdsa-sha2-nistp256":
            _ = try readString(from: privateSection, offset: &pOff) // curve id
            _ = try readBytes(from: privateSection, offset: &pOff)  // public key
            let privBytes = try readBytes(from: privateSection, offset: &pOff)
            let key = try P256.Signing.PrivateKey(rawRepresentation: privBytes)
            return .p256(username: username, privateKey: key)

        case "ecdsa-sha2-nistp384":
            _ = try readString(from: privateSection, offset: &pOff)
            _ = try readBytes(from: privateSection, offset: &pOff)
            let privBytes = try readBytes(from: privateSection, offset: &pOff)
            let key = try P384.Signing.PrivateKey(rawRepresentation: privBytes)
            return .p384(username: username, privateKey: key)

        case "ecdsa-sha2-nistp521":
            _ = try readString(from: privateSection, offset: &pOff)
            _ = try readBytes(from: privateSection, offset: &pOff)
            let privBytes = try readBytes(from: privateSection, offset: &pOff)
            let key = try P521.Signing.PrivateKey(rawRepresentation: privBytes)
            return .p521(username: username, privateKey: key)

        default:
            throw KeyError.unsupportedKeyType
        }
    }

    // MARK: - Binary helpers

    private static func readUInt32(from data: Data, offset: inout Int) throws -> UInt32 {
        guard offset + 4 <= data.count else { throw KeyError.invalidKeyData }
        let val = UInt32(data[offset]) << 24 | UInt32(data[offset+1]) << 16 |
                  UInt32(data[offset+2]) << 8  | UInt32(data[offset+3])
        offset += 4
        return val
    }

    private static func readBytes(from data: Data, offset: inout Int) throws -> Data {
        let len = Int(try readUInt32(from: data, offset: &offset))
        guard len >= 0, offset + len <= data.count else { throw KeyError.invalidKeyData }
        let result = Data(data[offset..<(offset + len)])
        offset += len
        return result
    }

    private static func readString(from data: Data, offset: inout Int) throws -> String {
        let bytes = try readBytes(from: data, offset: &offset)
        return String(data: bytes, encoding: .utf8) ?? ""
    }

}
