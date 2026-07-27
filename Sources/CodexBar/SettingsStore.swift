import AppKit
import Combine
import Foundation
import ServiceManagement

enum RefreshFrequency: String, CaseIterable, Identifiable {
    case manual
    case oneMinute
    case twoMinutes
    case fiveMinutes
    case fifteenMinutes
    case thirtyMinutes

    var id: String { rawValue }

    var seconds: TimeInterval? {
        switch self {
        case .manual: return nil
        case .oneMinute: return 60
        case .twoMinutes: return 120
        case .fiveMinutes: return 300
        case .fifteenMinutes: return 900
        case .thirtyMinutes: return 1800
        }
    }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .oneMinute: return "1 min"
        case .twoMinutes: return "2 min"
        case .fiveMinutes: return "5 min"
        case .fifteenMinutes: return "15 min"
        case .thirtyMinutes: return "30 min"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var refreshFrequency: RefreshFrequency {
        didSet { UserDefaults.standard.set(refreshFrequency.rawValue, forKey: Keys.refreshFrequency) }
    }

    @Published var enabledProviders: Set<ProviderID> {
        didSet {
            let raw = enabledProviders.map(\.rawValue).sorted()
            UserDefaults.standard.set(raw, forKey: Keys.enabledProviders)
        }
    }

    @Published var selectedProvider: ProviderID {
        didSet { UserDefaults.standard.set(selectedProvider.rawValue, forKey: Keys.selectedProvider) }
    }

    @Published var mergeIcons: Bool {
        didSet { UserDefaults.standard.set(mergeIcons, forKey: Keys.mergeIcons) }
    }

    @Published var lowQuotaNotifications: Bool {
        didSet { UserDefaults.standard.set(lowQuotaNotifications, forKey: Keys.lowQuotaNotifications) }
    }

    @Published var lowQuotaThreshold: Double {
        didSet { UserDefaults.standard.set(lowQuotaThreshold, forKey: Keys.lowQuotaThreshold) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            applyLaunchAtLogin(launchAtLogin)
        }
    }

    private enum Keys {
        static let refreshFrequency = "refreshFrequency"
        static let enabledProviders = "enabledProviders"
        static let selectedProvider = "selectedProvider"
        static let mergeIcons = "mergeIcons"
        static let lowQuotaNotifications = "lowQuotaNotifications"
        static let lowQuotaThreshold = "lowQuotaThreshold"
        static let launchAtLogin = "launchAtLogin"
    }

    init(userDefaults: UserDefaults = .standard) {
        let rawFreq = userDefaults.string(forKey: Keys.refreshFrequency) ?? RefreshFrequency.twoMinutes.rawValue
        self.refreshFrequency = RefreshFrequency(rawValue: rawFreq) ?? .twoMinutes

        if let arr = userDefaults.array(forKey: Keys.enabledProviders) as? [String] {
            let set = Set(arr.compactMap(ProviderID.init(rawValue:)))
            self.enabledProviders = set.isEmpty ? [.codex] : set
        } else {
            self.enabledProviders = [.codex, .claude, .grok]
        }

        if let raw = userDefaults.string(forKey: Keys.selectedProvider),
           let id = ProviderID(rawValue: raw)
        {
            self.selectedProvider = id
        } else {
            self.selectedProvider = .codex
        }

        // Merge-icons is unused in the single-status-item UI; keep the key for prefs compatibility.
        self.mergeIcons = true
        self.lowQuotaNotifications = userDefaults.object(forKey: Keys.lowQuotaNotifications) as? Bool ?? false
        let threshold = userDefaults.object(forKey: Keys.lowQuotaThreshold) as? Double ?? 20
        self.lowQuotaThreshold = threshold
        // Do not register launch-at-login during init; only on explicit user toggle.
        self.launchAtLogin = userDefaults.bool(forKey: Keys.launchAtLogin)
    }

    func setProvider(_ id: ProviderID, enabled: Bool) {
        var next = enabledProviders
        if enabled {
            next.insert(id)
        } else if next.count > 1 {
            next.remove(id)
            if selectedProvider == id {
                selectedProvider = next.sorted { $0.rawValue < $1.rawValue }.first ?? .codex
            }
        }
        enabledProviders = next
    }

    private func applyLaunchAtLogin(_ enabled: Bool) {
        // SMAppService is macOS 13+.
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Keep the preference; registration can fail when unsigned.
                NSLog("CodexBar launch-at-login error: \(error.localizedDescription)")
            }
        }
    }
}
