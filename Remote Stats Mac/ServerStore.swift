//
//  ServerStore.swift
//  Remote Stats Mac
//

import Foundation
import Observation
import SwiftUI

@Observable
class ServerStore {
    var servers: [ServerConfig] = []
    var statuses: [UUID: ServerStatus] = [:]
    var networkCache: [UUID: CachedNetworkInfo] = [:]
    var updateCache: [UUID: CachedUpdateInfo] = [:]

    private let storageKey = "savedServers_v1"
    private let statusStorageKey = "cachedServerStatuses_v1"
    private let networkCacheKey = "cachedNetworkInfo_v1"
    private let updateCacheKey = "cachedUpdateInfo_v1"
    private let iCloud = NSUbiquitousKeyValueStore.default

    init() {
        load()
        loadStatuses()
        loadNetworkCache()
        loadUpdateCache()
        observeiCloudChanges()
    }

    func add(_ server: ServerConfig) {
        servers.append(server)
        save()
    }

    func update(_ server: ServerConfig) {
        guard let idx = servers.firstIndex(where: { $0.id == server.id }) else { return }
        servers[idx] = server
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        servers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func delete(at offsets: IndexSet) {
        offsets.forEach {
            let id = servers[$0].id
            statuses.removeValue(forKey: id)
            networkCache.removeValue(forKey: id)
            updateCache.removeValue(forKey: id)
            KeychainService.delete(for: "server-\(id.uuidString)")
            KeychainService.delete(for: "server-key-\(id.uuidString)")
            Task { await SSHConnectionPool.shared.invalidate(id) }
        }
        servers.remove(atOffsets: offsets)
        save()
        saveStatuses()
        saveNetworkCache()
        saveUpdateCache()
    }

    func saveStatuses() {
        let flat = Dictionary(uniqueKeysWithValues: statuses.map { ($0.key.uuidString, $0.value) })
        guard let encoded = try? JSONEncoder().encode(flat) else { return }
        UserDefaults.standard.set(encoded, forKey: statusStorageKey)
    }

    private func loadStatuses() {
        guard let data = UserDefaults.standard.data(forKey: statusStorageKey),
              let flat = try? JSONDecoder().decode([String: ServerStatus].self, from: data) else { return }
        statuses = Dictionary(uniqueKeysWithValues: flat.compactMap { k, v in
            UUID(uuidString: k).map { ($0, v) }
        })
    }

    func saveNetworkCache() {
        let flat = Dictionary(uniqueKeysWithValues: networkCache.map { ($0.key.uuidString, $0.value) })
        guard let encoded = try? JSONEncoder().encode(flat) else { return }
        UserDefaults.standard.set(encoded, forKey: networkCacheKey)
    }

    private func loadNetworkCache() {
        guard let data = UserDefaults.standard.data(forKey: networkCacheKey),
              let flat = try? JSONDecoder().decode([String: CachedNetworkInfo].self, from: data) else { return }
        networkCache = Dictionary(uniqueKeysWithValues: flat.compactMap { k, v in
            UUID(uuidString: k).map { ($0, v) }
        })
    }

    func saveUpdateCache() {
        let flat = Dictionary(uniqueKeysWithValues: updateCache.map { ($0.key.uuidString, $0.value) })
        guard let encoded = try? JSONEncoder().encode(flat) else { return }
        UserDefaults.standard.set(encoded, forKey: updateCacheKey)
    }

    private func loadUpdateCache() {
        guard let data = UserDefaults.standard.data(forKey: updateCacheKey),
              let flat = try? JSONDecoder().decode([String: CachedUpdateInfo].self, from: data) else { return }
        updateCache = Dictionary(uniqueKeysWithValues: flat.compactMap { k, v in
            UUID(uuidString: k).map { ($0, v) }
        })
    }

    // MARK: - Persistence

    private func save() {
        let syncEnabled = SyncSettings.iCloudEnabled
        for server in servers {
            KeychainService.save(password: server.password, for: "server-\(server.id.uuidString)", synchronizable: syncEnabled)
            KeychainService.save(password: server.privateKey, for: "server-key-\(server.id.uuidString)", synchronizable: syncEnabled)
        }
        guard let encoded = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(encoded, forKey: storageKey)
        if syncEnabled {
            iCloud.synchronize()
            iCloud.set(encoded, forKey: storageKey)
            iCloud.synchronize()
        }
    }

    private func load() {
        let syncEnabled = SyncSettings.iCloudEnabled
        let data: Data?
        if syncEnabled {
            iCloud.synchronize()
            data = iCloud.data(forKey: storageKey) ?? UserDefaults.standard.data(forKey: storageKey)
        } else {
            data = UserDefaults.standard.data(forKey: storageKey)
        }
        guard let data, let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return }

        var needsMigration = false
        servers = decoded.map { server in
            var s = server
            if !s.password.isEmpty {
                KeychainService.save(password: s.password, for: "server-\(s.id.uuidString)", synchronizable: syncEnabled)
                needsMigration = true
            }
            if !s.privateKey.isEmpty {
                KeychainService.save(password: s.privateKey, for: "server-key-\(s.id.uuidString)", synchronizable: syncEnabled)
                needsMigration = true
            }
            s.password = KeychainService.load(for: "server-\(s.id.uuidString)") ?? ""
            s.privateKey = KeychainService.load(for: "server-key-\(s.id.uuidString)") ?? ""
            return s
        }
        if needsMigration || (syncEnabled && iCloud.data(forKey: storageKey) == nil) { save() }
    }

    // MARK: - iCloud Sync

    func enableiCloudSync() {
        for server in servers {
            KeychainService.save(password: server.password, for: "server-\(server.id.uuidString)", synchronizable: true)
            KeychainService.save(password: server.privateKey, for: "server-key-\(server.id.uuidString)", synchronizable: true)
        }
        guard let encoded = try? JSONEncoder().encode(servers) else { return }
        iCloud.set(encoded, forKey: storageKey)
        iCloud.synchronize()
    }

    func disableiCloudSync() {
        for server in servers {
            KeychainService.save(password: server.password, for: "server-\(server.id.uuidString)", synchronizable: false)
            KeychainService.save(password: server.privateKey, for: "server-key-\(server.id.uuidString)", synchronizable: false)
        }
        iCloud.removeObject(forKey: storageKey)
        iCloud.synchronize()
    }

    private func observeiCloudChanges() {
        Task {
            for await notification in NotificationCenter.default.notifications(named: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: nil) {
                guard SyncSettings.iCloudEnabled,
                      let userInfo = notification.userInfo,
                      let reason = userInfo[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int,
                      reason != NSUbiquitousKeyValueStoreQuotaViolationChange,
                      let keys = userInfo[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String],
                      keys.contains(storageKey) else { continue }
                reloadFromiCloud()
            }
        }
    }

    private func reloadFromiCloud() {
        guard let data = iCloud.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) else { return }

        let newIDs = Set(decoded.map { $0.id })
        for server in servers where !newIDs.contains(server.id) {
            KeychainService.delete(for: "server-\(server.id.uuidString)")
            KeychainService.delete(for: "server-key-\(server.id.uuidString)")
            statuses.removeValue(forKey: server.id)
            networkCache.removeValue(forKey: server.id)
            updateCache.removeValue(forKey: server.id)
        }

        servers = decoded.map { server in
            var s = server
            s.password = KeychainService.load(for: "server-\(s.id.uuidString)") ?? ""
            s.privateKey = KeychainService.load(for: "server-key-\(s.id.uuidString)") ?? ""
            return s
        }
        if let encoded = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
