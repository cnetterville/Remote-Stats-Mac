//
//  StatsParser.swift
//  Remote Stats Mac
//

import Foundation

struct StatsParser {
    static func parse(
        uptimeRaw: String,
        memoryRaw: String,
        loadRaw: String,
        temperatureRaw: String,
        bootTimeRaw: String,
        osVersionRaw: String,
        loginsRaw: String,
        cpuRaw: String,
        diskRaw: String,
        processesRaw: String,
        memProcessesRaw: String = "",
        dockerRaw: String = "",
        proxmoxRaw: String = "",
        powerRaw: String = "",
        networkRaw: String = ""
    ) -> ServerStats {
        let cpuInfo = parseCPU(cpuRaw)
        let network = parseNetwork(networkRaw)
        let pve = splitProxmoxSections(proxmoxRaw)
        return ServerStats(
            uptime:      parseUptime(uptimeRaw),
            memory:      parseMemory(memoryRaw),
            load:        parseLoad(loadRaw),
            temperatureCelsius: parseTemperature(temperatureRaw),
            bootTime:    parseBootTime(bootTimeRaw),
            osVersion:   parseOSVersion(osVersionRaw),
            logins:      parseLogins(loginsRaw),
            cpuModel:    cpuInfo.model,
            cpuCores:    cpuInfo.cores,
            cpuCoreDetails: cpuInfo.coreDetails,
            machineModel: cpuInfo.machineModel,
            disks:       parseDisks(diskRaw),
            processes:   parseProcesses(processesRaw),
            memoryProcesses: parseProcesses(memProcessesRaw),
            dockerContainers: parseDocker(dockerRaw),
            proxmoxGuests: parseProxmox(pve.vm),
            proxmoxStorage: parseProxmoxStorage(pve.storage),
            internalIP:  network.internalIP,
            hostname:    network.hostname,
            gateway:     network.gateway,
            networkInterface: network.networkInterface,
            linkSpeed:   network.linkSpeed,
            macAddress:  network.macAddress,
            dnsServers:  network.dnsServers,
            rxBytes:     network.rxBytes,
            txBytes:     network.txBytes,
            externalIP:  network.externalIP,
            isp:         network.isp,
            location:    network.location,
            powerWatts:  parsePower(powerRaw),
            piThrottleFlags: parsePiThrottle(powerRaw)
        )
    }

    // MARK: - Uptime
    static func parseUptime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let upRange = trimmed.range(of: "up ") else { return trimmed }
        let afterUp = String(trimmed[upRange.upperBound...])

        if let userRange = afterUp.range(of: #",\s+\d+\s+user"#, options: .regularExpression) {
            return String(afterUp[..<userRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return afterUp.components(separatedBy: ",").prefix(2).joined(separator: ",")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func parseLoadFromUptime(_ raw: String) -> String {
        guard let _ = raw.range(of: "load average", options: .caseInsensitive) else { return "" }
        let afterLoad = raw.components(separatedBy: "load average").last ?? ""
        guard let colonRange = afterLoad.range(of: ":") else { return "" }
        let numbers = String(afterLoad[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let parts = numbers.components(separatedBy: CharacterSet(charactersIn: ", ")).filter { !$0.isEmpty }
        return parts.first ?? ""
    }

    // MARK: - Memory
    static func parseMemory(_ raw: String) -> MemoryStats {
        var stats = MemoryStats()
        let lines = raw.components(separatedBy: .newlines)
        var foundMem = false

        for line in lines {
            if line.hasPrefix("Mem:") {
                let parts = line.split(separator: " ").filter { !$0.isEmpty }
                if parts.count >= 3,
                   let total = Int(parts[1]),
                   let used = Int(parts[2]) {
                    stats.totalMB = total
                    stats.usedMB = used
                    stats.freeMB = total - used
                    stats.usedPercent = total > 0 ? Double(used) / Double(total) : 0
                }
                foundMem = true
            } else if line.hasPrefix("Swap:") {
                let parts = line.split(separator: " ").filter { !$0.isEmpty }
                if parts.count >= 3,
                   let total = Int(parts[1]),
                   let used = Int(parts[2]) {
                    stats.swapTotalMB = total
                    stats.swapUsedMB = used
                    stats.swapFreeMB = total - used
                    stats.swapPercent = total > 0 ? Double(used) / Double(total) : 0
                }
                if foundMem { return stats }
            }
        }
        if foundMem { return stats }

        var pageSize = 4096
        var pagesActive = 0
        var pagesWired = 0
        var totalBytes = 0

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.contains("page size of") {
                if let match = t.range(of: #"(\d+) bytes"#, options: .regularExpression) {
                    let sub = String(t[match])
                    if let ps = sub.components(separatedBy: " ").first.flatMap({ Int($0) }) {
                        pageSize = ps
                    }
                }
            } else if t.hasPrefix("Pages active:") {
                pagesActive = extractInt(from: t)
            } else if t.hasPrefix("Pages wired down:") {
                pagesWired = extractInt(from: t)
            } else if t.hasPrefix("hw.memsize:") {
                if let val = t.components(separatedBy: " ").last.flatMap({ Int($0) }) {
                    totalBytes = val
                }
            }
        }

        if totalBytes > 0 {
            let usedPages = pagesActive + pagesWired
            let totalMB = totalBytes / 1024 / 1024
            let usedMB = usedPages * pageSize / 1024 / 1024
            stats.totalMB = totalMB
            stats.usedMB = min(usedMB, totalMB)
            stats.freeMB = totalMB - stats.usedMB
            stats.usedPercent = totalMB > 0 ? Double(stats.usedMB) / Double(totalMB) : 0
        }

        return stats
    }

    // MARK: - Load
    static func parseLoad(_ raw: String) -> LoadStats {
        var stats = LoadStats()
        let cleaned = raw
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = cleaned.split(separator: " ").filter { !$0.isEmpty }
        if parts.count >= 3 {
            stats.oneMin = String(parts[0])
            stats.fiveMin = String(parts[1])
            stats.fifteenMin = String(parts[2])
        }
        return stats
    }

    // MARK: - Temperature
    static func parseTemperature(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "N/A" else { return nil }
        if let milliDeg = Int(trimmed), milliDeg > 1000 {
            return Double(milliDeg) / 1000.0
        }
        return Double(trimmed)
    }

    static func parsePower(_ raw: String) -> Double? {
        let wattsSection: String
        if raw.contains("===PWR_THROTTLE===") {
            wattsSection = raw.components(separatedBy: "===PWR_THROTTLE===").first ?? ""
        } else {
            wattsSection = raw
        }
        let trimmed = wattsSection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "N/A" else { return nil }
        return Double(trimmed)
    }

    static func parsePiThrottle(_ raw: String) -> UInt32? {
        guard raw.contains("===PWR_THROTTLE===") else { return nil }
        let throttleSection = raw.components(separatedBy: "===PWR_THROTTLE===").last?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !throttleSection.isEmpty, throttleSection != "N/A" else { return nil }
        let hex = throttleSection.hasPrefix("0x") ? String(throttleSection.dropFirst(2)) : throttleSection
        return UInt32(hex, radix: 16)
    }

    // MARK: - Boot Time
    static func parseBootTime(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil {
            return trimmed
        }
        if let braceClose = trimmed.range(of: "}") {
            let rest = String(trimmed[braceClose.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty {
                let fmt = DateFormatter()
                fmt.locale = Locale(identifier: "en_US_POSIX")
                fmt.dateFormat = "EEE MMM d HH:mm:ss yyyy"
                if let date = fmt.date(from: rest) {
                    let out = DateFormatter()
                    out.dateFormat = "yyyy-MM-dd HH:mm:ss"
                    return out.string(from: date)
                }
                return rest
            }
        }
        return trimmed
    }

    // MARK: - OS Version
    static func parseOSVersion(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines).filter { !$0.isEmpty }

        if lines.count == 1 {
            return lines[0].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        var productName = ""
        var productVersion = ""
        for line in lines {
            let parts = line.components(separatedBy: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2 else { continue }
            if parts[0] == "ProductName"    { productName    = parts[1] }
            if parts[0] == "ProductVersion" { productVersion = parts[1] }
        }

        guard !productName.isEmpty else { return trimmed }

        if productName == "macOS", !productVersion.isEmpty,
           let marketingName = macOSMarketingName(for: productVersion) {
            return "macOS \(marketingName) \(productVersion)"
        }
        return productVersion.isEmpty ? productName : "\(productName) \(productVersion)"
    }

    private static func macOSMarketingName(for version: String) -> String? {
        let parts = version.components(separatedBy: ".")
        let major = parts.first.flatMap(Int.init) ?? 0
        let minor = parts.dropFirst().first.flatMap(Int.init) ?? 0

        switch major {
        case 15: return "Sequoia"
        case 14: return "Sonoma"
        case 13: return "Ventura"
        case 12: return "Monterey"
        case 11: return "Big Sur"
        case 10:
            switch minor {
            case 15: return "Catalina"
            case 14: return "Mojave"
            case 13: return "High Sierra"
            case 12: return "Sierra"
            default: return nil
            }
        default: return nil
        }
    }

    // MARK: - CPU
    static func parseCPU(_ raw: String) -> (model: String, cores: Int, coreDetails: String, machineModel: String) {
        let parts = raw.components(separatedBy: "---")
        let linuxModel = parts.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "CPU ", with: "")
            ?? ""
        let coresStr = parts.dropFirst().first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
        let fallbackCores = Int(coresStr) ?? 0
        let hwSection = parts.dropFirst(2).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if hwSection.contains("Hardware Overview") {
            let info = parseSystemProfiler(hwSection)
            let model = info.chip.isEmpty ? (linuxModel.isEmpty ? "--" : linuxModel) : info.chip
            let cores = info.totalCores > 0 ? info.totalCores : fallbackCores
            return (model, cores, info.coreDetails, info.modelName)
        }

        let machineModel = hwSection
        return (linuxModel.isEmpty ? "--" : linuxModel, fallbackCores, "", machineModel)
    }

    private static func parseSystemProfiler(_ raw: String) -> (chip: String, totalCores: Int, coreDetails: String, modelName: String) {
        var chip = ""
        var totalCores = 0
        var coreDetails = ""
        var modelName = ""

        for line in raw.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let kv = trimmed.components(separatedBy: ": ")
            guard kv.count >= 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv.dropFirst().joined(separator: ": ").trimmingCharacters(in: .whitespaces)

            switch key {
            case "Chip":
                chip = value
            case "Processor Name":
                if chip.isEmpty { chip = value }
            case "Model Name":
                modelName = value
            case "Total Number of Cores":
                if let parenStart = value.range(of: "(") {
                    totalCores = Int(value[..<parenStart.lowerBound].trimmingCharacters(in: .whitespaces)) ?? 0
                    coreDetails = String(value[parenStart.lowerBound...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                } else {
                    totalCores = Int(value) ?? 0
                }
            case "Number of CPUs":
                if totalCores == 0 { totalCores = Int(value) ?? 0 }
            default:
                break
            }
        }
        return (chip, totalCores, coreDetails, modelName)
    }

    // MARK: - Logins
    static func parseLogins(_ raw: String) -> [LoginEntry] {
        if raw.contains("SESSIONNAME") {
            return parseWindowsLogins(raw)
        }

        var entries: [LoginEntry] = []
        var seen = Set<String>()

        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty,
                  !t.hasPrefix("wtmp"), !t.hasPrefix("btmp"),
                  !t.hasPrefix("USER"), !t.hasPrefix("NAME") else { continue }

            let parts = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3 else { continue }

            let user = parts[0]
            guard user != "reboot", user != "shutdown", !user.hasPrefix("-") else { continue }

            let terminal = parts[1]
            let key = "\(user)_\(terminal)"
            guard !seen.contains(key) else { continue }

            let isWhoFormat = parts.last?.hasPrefix("(") == true
            let from: String
            let dateStr: String
            let isActive: Bool

            if isWhoFormat {
                from = (parts.last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "()"))
                let dateParts = parts.count >= 4 ? Array(parts[2..<(parts.count - 1)]) : []
                dateStr = dateParts.joined(separator: " ")
                isActive = true
            } else {
                from = parts.count >= 3 ? parts[2] : ""
                var dp: [String] = []
                for i in 3..<min(parts.count, 9) {
                    if parts[i] == "still" { break }
                    dp.append(parts[i])
                }
                dateStr = dp.joined(separator: " ")
                isActive = t.contains("still logged in")
            }

            seen.insert(key)
            entries.append(LoginEntry(
                user: user, terminal: terminal, from: from,
                dateString: dateStr, isActive: isActive
            ))
        }
        return entries
    }

    private static func parseWindowsLogins(_ raw: String) -> [LoginEntry] {
        var entries: [LoginEntry] = []
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.contains("SESSIONNAME") else { continue }

            let cleaned = t.hasPrefix(">") ? String(t.dropFirst()) : t
            let parts = cleaned.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 4 else { continue }

            let user = parts[0]
            let isActive = parts.contains { $0.caseInsensitiveCompare("Active") == .orderedSame }
            let isDisc = parts.contains { $0.caseInsensitiveCompare("Disc") == .orderedSame }
            guard isActive || isDisc else { continue }

            let session = Int(parts[1]) == nil ? parts[1] : "-"

            entries.append(LoginEntry(
                user: user,
                terminal: session,
                from: "-",
                dateString: "",
                isActive: isActive
            ))
        }
        return entries
    }

    // MARK: - Disk
    static func parseDisks(_ raw: String) -> [MountPoint] {
        let sections = raw.components(separatedBy: "===APFS_CONTAINER===")
        let dfRaw = sections.first ?? raw
        let containerInfo = sections.count >= 2 ? parseAPFSContainer(sections[1]) : nil

        var mounts: [MountPoint] = []
        for line in dfRaw.components(separatedBy: .newlines) where !line.isEmpty {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 6, Double(cols[1]) != nil else { continue }
            let mountPath = cols[5...].joined(separator: " ")
            var totalKB = Double(cols[1]) ?? 0
            var usedKB  = Double(cols[2]) ?? 0
            var freeKB  = Double(cols[3]) ?? 0

            if mountPath == "/", let c = containerInfo {
                totalKB = c.totalBytes / 1024.0
                freeKB = c.freeBytes / 1024.0
                usedKB = max(0, totalKB - freeKB)
            }

            guard totalKB > 0 else { continue }
            mounts.append(MountPoint(
                mountPath: mountPath,
                totalGB: totalKB / 1_048_576,
                usedGB: usedKB / 1_048_576,
                freeGB: freeKB / 1_048_576,
                usedPercent: usedKB / totalKB
            ))
        }
        return mounts.sorted { $0.mountPath < $1.mountPath }
    }

    private static func parseAPFSContainer(_ raw: String) -> (totalBytes: Double, freeBytes: Double)? {
        var total: Double?
        var free: Double?
        for line in raw.components(separatedBy: .newlines) {
            if line.contains("Container Total Space"), let bytes = extractBytes(from: line) {
                total = bytes
            } else if line.contains("Container Free Space"), let bytes = extractBytes(from: line) {
                free = bytes
            }
        }
        guard let t = total, let f = free else { return nil }
        return (t, f)
    }

    private static func extractBytes(from line: String) -> Double? {
        guard let parenStart = line.range(of: "("),
              let bytesEnd = line.range(of: " Bytes", range: parenStart.upperBound..<line.endIndex)
        else { return nil }
        let numStr = String(line[parenStart.upperBound..<bytesEnd.lowerBound])
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Double(numStr)
    }

    // MARK: - Processes
    static func parseProcesses(_ raw: String) -> [ProcessEntry] {
        var entries: [ProcessEntry] = []
        for line in raw.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !t.hasPrefix("USER") else { continue }
            let parts = t.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: true)
                         .map(String.init)
            guard parts.count >= 11 else { continue }
            entries.append(ProcessEntry(
                pid:     parts[1],
                user:    parts[0],
                cpu:     Double(parts[2]) ?? 0,
                mem:     Double(parts[3]) ?? 0,
                command: parts[10]
            ))
        }
        return entries
    }

    // MARK: - Network
    struct NetworkInfo {
        var internalIP = ""
        var hostname = ""
        var gateway = ""
        var networkInterface = ""
        var linkSpeed = ""
        var macAddress = ""
        var rxBytes: Int64 = 0
        var txBytes: Int64 = 0
        var dnsServers = ""
        var externalIP = ""
        var isp = ""
        var location = ""
    }

    static func parseNetwork(_ raw: String) -> NetworkInfo {
        let parts = raw.components(separatedBy: "---")
        func p(_ i: Int) -> String {
            i < parts.count ? parts[i].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }

        var info = NetworkInfo()
        info.internalIP = p(0)
        info.hostname = p(1)
        info.gateway = p(2)

        let ifLines = p(3).components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        func ifLine(_ i: Int) -> String {
            guard i < ifLines.count else { return "" }
            return ifLines[i] == "-" ? "" : ifLines[i]
        }
        info.networkInterface = ifLine(0)
        info.linkSpeed = ifLine(1)
        info.macAddress = ifLine(2)
        if ifLines.count >= 4 { info.rxBytes = Int64(ifLines[3]) ?? 0 }
        if ifLines.count >= 5 { info.txBytes = Int64(ifLines[4]) ?? 0 }

        info.dnsServers = p(4)

        let jsonStr = p(5)
        if let data = jsonStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            info.externalIP = json["ip"] as? String ?? ""
            let org = json["org"] as? String ?? ""
            info.isp = org.contains(" ") ? String(org[org.index(after: org.firstIndex(of: " ")!)...]) : org
            let city = json["city"] as? String ?? ""
            let region = json["region"] as? String ?? ""
            info.location = [city, region].filter { !$0.isEmpty }.joined(separator: ", ")
        }

        return info
    }

    // MARK: - Docker
    static func parseDocker(_ raw: String) -> [DockerContainer] {
        let lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return lines.compactMap { line in
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 5 else { return nil }
            return DockerContainer(
                id: cols[0],
                name: cols[1],
                image: cols[2],
                status: cols[3],
                state: cols[4],
                ports: cols.count > 5 ? cols[5] : "",
                composeProject: cols.count > 6 ? cols[6] : "",
                composeService: cols.count > 7 ? cols[7] : ""
            )
        }
    }

    // MARK: - Proxmox
    private static func splitProxmoxSections(_ raw: String) -> (vm: String, storage: String) {
        if raw.contains("===PVE_VM===") {
            let parts = raw.components(separatedBy: "===PVE_STORAGE===")
            let vmPart = parts.first?.replacingOccurrences(of: "===PVE_VM===", with: "") ?? ""
            let storagePart = parts.count > 1 ? parts[1] : ""
            return (vmPart.trimmingCharacters(in: .whitespacesAndNewlines),
                    storagePart.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return (raw, "")
    }

    static func parseProxmox(_ raw: String) -> [ProxmoxGuest] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let vmid = item["vmid"] as? Int,
                  let type = item["type"] as? String,
                  let status = item["status"] as? String else { return nil }
            let name = item["name"] as? String ?? "VM \(vmid)"
            let maxmem = item["maxmem"] as? Int ?? 0
            let mem = item["mem"] as? Int ?? 0
            let maxdisk = item["maxdisk"] as? Int ?? 0
            let uptime = item["uptime"] as? Int ?? 0
            let cpu = item["cpu"] as? Double ?? 0
            let maxcpu = item["maxcpu"] as? Int ?? 1
            let node = item["node"] as? String ?? ""
            return ProxmoxGuest(
                id: String(vmid),
                type: type,
                name: name,
                status: status,
                memoryMB: maxmem / 1_048_576,
                memUsedMB: mem / 1_048_576,
                diskGB: Double(maxdisk) / 1_073_741_824,
                uptimeSeconds: uptime,
                cpuUsage: cpu,
                cpuCount: maxcpu,
                node: node
            )
        }.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
    }

    static func parseProxmoxStorage(_ raw: String) -> [ProxmoxStorage] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let storage = item["storage"] as? String,
                  let node = item["node"] as? String else { return nil }
            let maxdisk = item["maxdisk"] as? Int64 ?? (item["maxdisk"] as? Int).map { Int64($0) } ?? 0
            let disk = item["disk"] as? Int64 ?? (item["disk"] as? Int).map { Int64($0) } ?? 0
            let status = item["status"] as? String ?? ""
            let type = item["plugintype"] as? String ?? item["type"] as? String ?? ""
            return ProxmoxStorage(
                storage: storage,
                node: node,
                type: type,
                totalBytes: maxdisk,
                usedBytes: disk,
                status: status
            )
        }.sorted { $0.storage < $1.storage }
    }

    static func parseProxmoxStorageNames(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0["storage"] as? String }
    }

    static func parseProxmoxBackups(_ raw: String) -> [ProxmoxBackup] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let volid = item["volid"] as? String else { return nil }
            let size = item["size"] as? Int64 ?? (item["size"] as? Int).map { Int64($0) } ?? 0
            let storage = (volid.split(separator: ":").first.map(String.init)) ?? ""
            let format = item["format"] as? String ?? ""
            let vmid = item["vmid"] as? Int ?? 0
            let notes = item["notes"] as? String ?? ""
            var date: Date?
            if let ctime = item["ctime"] as? Int {
                date = Date(timeIntervalSince1970: TimeInterval(ctime))
            }
            return ProxmoxBackup(volid: volid, storage: storage, size: size, date: date, format: format, vmid: vmid, notes: notes)
        }
    }

    static func parseProxmoxSnapshots(_ raw: String) -> [ProxmoxSnapshot] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let name = item["name"] as? String, name != "current" else { return nil }
            let desc = item["description"] as? String ?? ""
            let parent = item["parent"] as? String ?? ""
            var date: Date?
            if let ts = item["snaptime"] as? Int {
                date = Date(timeIntervalSince1970: TimeInterval(ts))
            }
            return ProxmoxSnapshot(name: name, description: desc, date: date, parent: parent)
        }.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    static func parseProxmoxTasks(_ raw: String) -> [ProxmoxTask] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("["),
              let data = trimmed.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            guard let upid = item["upid"] as? String else { return nil }
            let type = item["type"] as? String ?? ""
            let status = item["status"] as? String ?? ""
            let node = item["node"] as? String ?? ""
            let user = item["user"] as? String ?? ""
            var startTime: Date?
            var endTime: Date?
            if let st = item["starttime"] as? Int { startTime = Date(timeIntervalSince1970: TimeInterval(st)) }
            if let et = item["endtime"] as? Int { endTime = Date(timeIntervalSince1970: TimeInterval(et)) }
            return ProxmoxTask(upid: upid, type: type, status: status, startTime: startTime, endTime: endTime, node: node, user: user)
        }
    }

    static func parseProxmoxGuestConfig(_ raw: String, type: String) -> ProxmoxGuestConfig {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ProxmoxGuestConfig(cores: 0, sockets: 1, memoryMB: 0, osType: "", networkInterfaces: [], description: "")
        }
        let cores = obj["cores"] as? Int ?? 1
        let sockets = obj["sockets"] as? Int ?? 1
        let memoryMB = obj["memory"] as? Int ?? 0
        let osType = obj["ostype"] as? String ?? ""
        let desc = obj["description"] as? String ?? ""

        var nics: [ProxmoxNetworkInterface] = []
        for i in 0..<8 {
            let key = "net\(i)"
            guard let val = obj[key] as? String else { continue }
            let nic = parseProxmoxNIC(key: key, value: val, guestType: type)
            nics.append(nic)
        }

        return ProxmoxGuestConfig(cores: cores, sockets: sockets, memoryMB: memoryMB, osType: osType, networkInterfaces: nics, description: desc)
    }

    private static func parseProxmoxNIC(key: String, value: String, guestType: String) -> ProxmoxNetworkInterface {
        var hwaddr = "", bridge = "", model = "", tag: Int?
        var firewall = false
        let parts = value.components(separatedBy: ",")
        for part in parts {
            let kv = part.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
            guard kv.count == 2 else {
                if part.contains("=") { continue }
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.contains(":") { hwaddr = p } else { model = p }
                continue
            }
            switch kv[0].trimmingCharacters(in: .whitespaces) {
            case "hwaddr": hwaddr = kv[1]
            case "bridge": bridge = kv[1]
            case "firewall": firewall = kv[1] == "1"
            case "tag": tag = Int(kv[1])
            case let k where k == "virtio" || k == "e1000" || k == "rtl8139":
                model = k; hwaddr = kv[1]
            case "name": model = kv[1]
            default: break
            }
        }
        return ProxmoxNetworkInterface(name: key, hwaddr: hwaddr, bridge: bridge, model: model, firewall: firewall, tag: tag)
    }

    // MARK: - Helpers
    private static func extractInt(from line: String) -> Int {
        let digits = line.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
        return Int(digits) ?? 0
    }
}
