import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var lastGlobalError: String?

    private let settings: SettingsStore
    private var timerTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var notifiedLow: Set<ProviderID> = []

    init(settings: SettingsStore) {
        self.settings = settings
        bindSettings()
        // Defer first refresh off the cold-launch path so MenuBarExtra can mount.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            await self?.refresh()
            self?.startTimer()
            self?.requestNotificationPermissionIfNeeded()
        }
    }

    func snapshot(for id: ProviderID) -> ProviderSnapshot? {
        snapshots[id]
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let providers = Array(settings.enabledProviders)
        await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, Error>).self) { group in
            for id in providers {
                group.addTask {
                    do {
                        let snap = try await Self.fetch(id)
                        return (id, .success(snap))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            var next = snapshots
            var errors: [String] = []
            for await (id, result) in group {
                switch result {
                case let .success(snap):
                    next[id] = snap
                    evaluateLowQuota(snap)
                case let .failure(error):
                    let message = error.localizedDescription
                    errors.append("\(id.displayName): \(message)")
                    next[id] = ProviderSnapshot(
                        id: id,
                        windows: next[id]?.windows ?? [],
                        accountLine: next[id]?.accountLine,
                        detailLines: next[id]?.detailLines ?? [],
                        updatedAt: Date(),
                        error: message)
                    notifiedLow.remove(id)
                }
            }
            snapshots = next
            lastGlobalError = errors.isEmpty ? nil : errors.joined(separator: " | ")
        }
    }

    private static func fetch(_ id: ProviderID) async throws -> ProviderSnapshot {
        switch id {
        case .codex:
            return try CodexUsageFetcher.loadLatestUsage()
        case .claude:
            return try await ClaudeUsageFetcher.loadUsage()
        case .openrouter:
            return try await OpenRouterUsageFetcher.loadUsage()
        case .grok:
            return try GrokUsageFetcher.loadUsage()
        }
    }

    private func bindSettings() {
        settings.$refreshFrequency
            .sink { [weak self] _ in self?.startTimer() }
            .store(in: &cancellables)

        settings.$enabledProviders
            .dropFirst()
            .sink { [weak self] _ in
                Task { await self?.refresh() }
            }
            .store(in: &cancellables)
    }

    private func startTimer() {
        timerTask?.cancel()
        guard let wait = settings.refreshFrequency.seconds else { return }
        timerTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                await self?.refresh()
            }
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        guard settings.lowQuotaNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func evaluateLowQuota(_ snap: ProviderSnapshot) {
        guard settings.lowQuotaNotifications else { return }
        guard let lowest = snap.lowestRemaining else { return }
        if lowest > settings.lowQuotaThreshold {
            notifiedLow.remove(snap.id)
            return
        }
        guard !notifiedLow.contains(snap.id) else { return }
        notifiedLow.insert(snap.id)

        let content = UNMutableNotificationContent()
        content.title = "\(snap.id.displayName) quota low"
        content.body = String(format: "%.0f%% remaining (threshold %.0f%%)", lowest, settings.lowQuotaThreshold)
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "low-\(snap.id.rawValue)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    deinit {
        timerTask?.cancel()
    }
}
