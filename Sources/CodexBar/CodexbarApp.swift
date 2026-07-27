import AppKit
import Combine
import ServiceManagement
import SwiftUI

// MARK: - Rows

struct UsageRow: View {
    let title: String
    let window: RateWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(String(format: "%.0f%% left (%.0f%% used)", window.remainingPercent, window.usedPercent))
            if let countdown = window.resetCountdown {
                Text(countdown)
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
            } else if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundColor(Color(nsColor: .secondaryLabelColor))
            }
        }
    }
}

struct ProviderMenuContent: View {
    let provider: ProviderID
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    private var snapshot: ProviderSnapshot? { store.snapshot(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider.displayName).font(.title3.weight(.semibold))

            if let snapshot {
                if let error = snapshot.error, snapshot.windows.isEmpty {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                } else {
                    ForEach(snapshot.windows) { named in
                        UsageRow(title: named.title, window: named.window)
                    }
                    if let error = snapshot.error {
                        Text(error).font(.caption).foregroundColor(.orange)
                    }
                    if let account = snapshot.accountLine {
                        Text(account)
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                    ForEach(snapshot.detailLines, id: \.self) { line in
                        Text(line)
                            .font(.caption)
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                    }
                    Text("Updated \(snapshot.updatedAt.formatted(date: .omitted, time: .shortened))")
                        .foregroundColor(Color(nsColor: .secondaryLabelColor))
                }
            } else {
                Text("No usage yet").foregroundStyle(.secondary)
            }

            sharedControls
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 260, alignment: .leading)
    }

    @ViewBuilder
    private var sharedControls: some View {
        Divider()
        if settings.mergeIcons {
            providerSwitcher
            Divider()
        }
        providerToggles
        Divider()
        Menu("Refresh every: \(settings.refreshFrequency.label)") {
            ForEach(RefreshFrequency.allCases) { option in
                Button {
                    settings.refreshFrequency = option
                } label: {
                    if settings.refreshFrequency == option {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        }
        Toggle("Merge icons (one menu)", isOn: $settings.mergeIcons)
        Toggle("Low-quota notifications", isOn: $settings.lowQuotaNotifications)
        Toggle("Launch at login", isOn: $settings.launchAtLogin)
        Button {
            Task { await store.refresh() }
        } label: {
            Label(store.isRefreshing ? "Refreshing…" : "Refresh now", systemImage: "arrow.clockwise")
        }
        Divider()
        Button("About CodexBar") { showAbout() }
        Button("View upstream GitHub") {
            if let url = URL(string: "https://github.com/steipete/CodexBar") {
                NSWorkspace.shared.open(url)
            }
        }
        Button("Quit") { NSApp.terminate(nil) }
    }

    private var providerSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(ProviderID.allCases) { id in
                if settings.enabledProviders.contains(id) {
                    Button(id.shortLabel) {
                        settings.selectedProvider = id
                    }
                    .buttonStyle(.bordered)
                    .tint(settings.selectedProvider == id ? .accentColor : .gray)
                }
            }
        }
    }

    private var providerToggles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Providers").font(.caption).foregroundStyle(.secondary)
            ForEach(ProviderID.allCases) { id in
                Toggle(id.displayName, isOn: Binding(
                    get: { settings.enabledProviders.contains(id) },
                    set: { on in settings.setProvider(id, enabled: on) }))
            }
        }
    }
}

struct MergedMenuContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ProviderMenuContent(
            provider: settings.selectedProvider,
            store: store,
            settings: settings)
    }
}

struct IconView: View {
    let snapshot: ProviderSnapshot?
    let badge: String?
    let isStale: Bool

    var body: some View {
        if let snapshot, snapshot.error == nil || !snapshot.windows.isEmpty {
            Image(nsImage: IconRenderer.makeIcon(
                primaryRemaining: snapshot.primaryRemaining,
                weeklyRemaining: snapshot.secondaryRemaining,
                stale: isStale || snapshot.error != nil,
                badge: badge))
        } else {
            Image(systemName: "chart.bar.fill")
        }
    }
}

// MARK: - App

@main
struct CodexBarApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var store: UsageStore

    init() {
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: UsageStore(settings: settings))
    }

    var body: some Scene {
        // Merged single status item
        MenuBarExtra(isInserted: mergedBinding) {
            MergedMenuContent(store: store, settings: settings)
        } label: {
            let id = settings.selectedProvider
            let snap = store.snapshot(for: id)
            IconView(
                snapshot: snap,
                badge: id.shortLabel,
                isStale: snap?.error != nil)
        }

        // Separate status items when not merged
        ForEach(ProviderID.allCases) { id in
            MenuBarExtra(isInserted: separateBinding(id)) {
                ProviderMenuContent(provider: id, store: store, settings: settings)
            } label: {
                let snap = store.snapshot(for: id)
                IconView(
                    snapshot: snap,
                    badge: id.shortLabel,
                    isStale: snap?.error != nil)
            }
        }

        Settings {
            EmptyView()
        }
    }

    private var mergedBinding: Binding<Bool> {
        Binding(
            get: { settings.mergeIcons },
            set: { settings.mergeIcons = $0 })
    }

    private func separateBinding(_ id: ProviderID) -> Binding<Bool> {
        Binding(
            get: { !settings.mergeIcons && settings.enabledProviders.contains(id) },
            set: { on in
                if on {
                    settings.mergeIcons = false
                    settings.setProvider(id, enabled: true)
                } else {
                    settings.setProvider(id, enabled: false)
                }
            })
    }
}

@MainActor
private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "CodexBar 0.2.0 (macOS 13)"
    alert.informativeText = """
    Multi-provider fork for Intel macOS 13.
    Providers: Codex · Claude · OpenRouter · Grok
    Based on steipete/CodexBar (MIT)
    Modern features: provider switcher, countdowns, low-quota alerts, launch-at-login, 15/30m refresh.
    Full 0.45.x requires macOS 14+.
    """
    alert.icon = NSApplication.shared.applicationIconImage
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
