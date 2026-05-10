//
//  NUTStore.swift
//  Remote Stats Mac
//

import Foundation
import Observation
import SwiftUI

@Observable
class NUTStore {
    var configs: [NUTConfig] = []
    var statuses: [UUID: UPSRowStatus] = [:]

    private let storageKey = "savedNUTConfigs_v1"
    private let iCloud = NSUbiquitousKeyValueStore.default

    init() {
        load()
        observeiCloudChanges()
    }

    func add(_ config: NUTConfig) {
        configs.append(config)
        save()
    }

    func update(_ config: NUTConfig) {
        guard let idx = configs.firstIndex(where: { $0.id == config.id }) else { return }
        configs[idx] = config
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        configs.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func delete(at offsets: IndexSet) {
        offsets.forEach {
            let id = configs[$0].id
            statuses.removeValue(forKey: id)
            KeychainService.delete(for: "nut-\(id.uuidString)")
        }
        configs.remove(atOffsets: offsets)
        save()
    }

    // MARK: - Persistence

    private func save() {
        let syncEnabled = SyncSettings.iCloudEnabled
        for config in configs {
            KeychainService.save(password: config.password, for: "nut-\(config.id.uuidString)", synchronizable: syncEnabled)
        }
        guard let encoded = try? JSONEncoder().encode(configs) else { return }
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
        guard let data, let decoded = try? JSONDecoder().decode([NUTConfig].self, from: data) else { return }

        var needsMigration = false
        configs = decoded.map { config in
            var c = config
            if !c.password.isEmpty {
                KeychainService.save(password: c.password, for: "nut-\(c.id.uuidString)", synchronizable: syncEnabled)
                needsMigration = true
            }
            c.password = KeychainService.load(for: "nut-\(c.id.uuidString)") ?? ""
            return c
        }
        if needsMigration || (syncEnabled && iCloud.data(forKey: storageKey) == nil) { save() }
    }

    // MARK: - iCloud Sync

    func enableiCloudSync() {
        for config in configs {
            KeychainService.save(password: config.password, for: "nut-\(config.id.uuidString)", synchronizable: true)
        }
        guard let encoded = try? JSONEncoder().encode(configs) else { return }
        iCloud.set(encoded, forKey: storageKey)
        iCloud.synchronize()
    }

    func disableiCloudSync() {
        for config in configs {
            KeychainService.save(password: config.password, for: "nut-\(config.id.uuidString)", synchronizable: false)
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
              let decoded = try? JSONDecoder().decode([NUTConfig].self, from: data) else { return }

        let newIDs = Set(decoded.map { $0.id })
        for config in configs where !newIDs.contains(config.id) {
            KeychainService.delete(for: "nut-\(config.id.uuidString)")
            statuses.removeValue(forKey: config.id)
        }

        configs = decoded.map { config in
            var c = config
            c.password = KeychainService.load(for: "nut-\(c.id.uuidString)") ?? ""
            return c
        }
        if let encoded = try? JSONEncoder().encode(configs) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
