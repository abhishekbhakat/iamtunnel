//
//  SettingsManager.swift
//  SSMTunnelManager
//
//  Created by Lsn-Adarsh on 24/03/26.
//

import Foundation
import ServiceManagement

extension UserDefaults {
    static let appDefaults = UserDefaults(suiteName: Bundle.main.bundleIdentifier) ?? .standard
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()

    @Published var launchAtLogin: Bool = false {
        didSet { applyLaunchAtLogin() }
    }

    @Published var notifyOnConnect: Bool = true {
        didSet { UserDefaults.appDefaults.set(notifyOnConnect, forKey: "notifyOnConnect") }
    }

    @Published var notifyOnDisconnect: Bool = true {
        didSet { UserDefaults.appDefaults.set(notifyOnDisconnect, forKey: "notifyOnDisconnect") }
    }

    @Published var showActiveCount: Bool = true {
        didSet { UserDefaults.appDefaults.set(showActiveCount, forKey: "showActiveCount") }
    }

    init() {
        // Load saved preferences
        notifyOnConnect    = UserDefaults.appDefaults.object(forKey: "notifyOnConnect")    as? Bool ?? true
        notifyOnDisconnect = UserDefaults.appDefaults.object(forKey: "notifyOnDisconnect") as? Bool ?? true
        showActiveCount    = UserDefaults.appDefaults.object(forKey: "showActiveCount")    as? Bool ?? true

        // Check current launch at login state
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private func applyLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("❌ Launch at login error: \(error)")
            }
        }
    }
}
