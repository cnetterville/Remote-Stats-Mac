//
//  NUTService.swift
//  Remote Stats Mac
//

import Foundation
import Network

// MARK: - Public Service

struct NUTService {

    static func fetchStats(for config: NUTConfig) async throws -> UPSStats {
        try await withThrowingTaskGroup(of: UPSStats.self) { group in
            group.addTask {
                let client = NUTClient(host: config.host, port: config.port)
                do {
                    try await client.connect()
                    let vars = try await client.queryVars(
                        upsName: config.upsName,
                        username: config.username,
                        password: config.password
                    )
                    await client.disconnect()
                    var s = UPSStats()
                    s.rawStatus             = vars["ups.status"] ?? ""
                    s.batteryCharge         = vars["battery.charge"].flatMap(Double.init)
                    s.batteryRuntime        = vars["battery.runtime"].flatMap(Int.init)
                    s.batteryVoltage        = vars["battery.voltage"].flatMap(Double.init)
                    s.batteryVoltageNominal = vars["battery.voltage.nominal"].flatMap(Double.init)
                    s.load                  = vars["ups.load"].flatMap(Double.init)
                    s.inputVoltage          = vars["input.voltage"].flatMap(Double.init)
                    s.inputVoltageNominal   = vars["input.voltage.nominal"].flatMap(Double.init)
                    s.outputVoltage         = vars["output.voltage"].flatMap(Double.init)
                    s.model                 = vars["ups.model"] ?? vars["device.model"] ?? ""
                    s.manufacturer          = vars["ups.mfr"] ?? vars["device.mfr"] ?? ""
                    s.nominalPower          = vars["ups.power.nominal"].flatMap(Int.init)
                                           ?? vars["ups.realpower.nominal"].flatMap(Int.init)
                    return s
                } catch {
                    await client.disconnect()
                    throw error
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                throw NUTError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    static func checkStatus(for config: NUTConfig) async -> UPSRowStatus {
        do {
            let stats = try await fetchStats(for: config)
            return UPSRowStatus(
                isOnline: stats.isOnline,
                batteryCharge: stats.batteryCharge,
                batteryRuntime: stats.batteryRuntime,
                rawStatus: stats.rawStatus,
                isChecking: false,
                lastChecked: Date()
            )
        } catch {
            return UPSRowStatus(
                isOnline: false,
                isChecking: false,
                lastChecked: Date(),
                error: error.localizedDescription
            )
        }
    }

}

// MARK: - Errors

enum NUTError: Error, LocalizedError {
    case connectionClosed
    case invalidResponse
    case serverError(String)
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .connectionClosed:    return "Connection closed by NUT server"
        case .invalidResponse:     return "Invalid response from NUT server"
        case .serverError(let m):  return m
        case .timeout:             return "NUT server did not respond in time"
        case .cancelled:           return "Cancelled"
        }
    }
}

// MARK: - NUT TCP Client

private actor NUTClient {
    private let connection: NWConnection
    private var buffer = ""

    init(host: String, port: Int) {
        let p = NWEndpoint.Port(rawValue: UInt16(port)) ?? 3493
        connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
    }

    func connect() async throws {
        final class Once: @unchecked Sendable { var done = false }
        let once = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                guard !once.done else { return }
                once.done = true
                switch state {
                case .ready:
                    cont.resume()
                case .failed(let error):
                    cont.resume(throwing: error)
                case .cancelled:
                    cont.resume(throwing: NUTError.cancelled)
                default:
                    once.done = false
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    func disconnect() {
        connection.cancel()
    }

    func queryVars(upsName: String, username: String, password: String) async throws -> [String: String] {
        if !username.isEmpty {
            try await sendLine("USERNAME \(username)")
            let r1 = try await readLine()
            guard r1.hasPrefix("OK") else { throw NUTError.serverError(r1) }
            try await sendLine("PASSWORD \(password)")
            let r2 = try await readLine()
            guard r2.hasPrefix("OK") else { throw NUTError.serverError(r2) }
        }

        try await sendLine("LIST VAR \(upsName)")
        let endMarker = "END LIST VAR \(upsName)"
        let response = try await readUntil(endMarker)
        return parseVars(response)
    }

    private func sendLine(_ text: String) async throws {
        let data = Data((text + "\n").utf8)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else         { cont.resume() }
            })
        }
    }

    private func readLine() async throws -> String {
        while !buffer.contains("\n") {
            buffer += try await receiveString()
        }
        guard let idx = buffer.firstIndex(of: "\n") else { throw NUTError.invalidResponse }
        let line = String(buffer[buffer.startIndex..<idx])
            .trimmingCharacters(in: .init(charactersIn: "\r"))
        buffer = String(buffer[buffer.index(after: idx)...])
        return line
    }

    private func readUntil(_ marker: String) async throws -> String {
        while !buffer.contains(marker) {
            if let errLine = buffer.components(separatedBy: "\n").first(where: { $0.hasPrefix("ERR") }) {
                throw NUTError.serverError(errLine)
            }
            buffer += try await receiveString()
        }
        return buffer
    }

    private func receiveString() async throws -> String {
        let data: Data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    cont.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else {
                    cont.resume(throwing: NUTError.connectionClosed)
                }
            }
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseVars(_ response: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in response.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.hasPrefix("VAR ") else { continue }
            let parts = String(t.dropFirst(4)).components(separatedBy: " ")
            guard parts.count >= 3 else { continue }
            let key = parts[1]
            let valueRaw = parts[2...].joined(separator: " ")
            result[key] = valueRaw.trimmingCharacters(in: .init(charactersIn: "\""))
        }
        return result
    }
}
