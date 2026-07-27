import AppKit
import Combine
import SwiftUI
import UserNotifications

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

struct MenuContent: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    private var provider: ProviderID { settings.selectedProvider }
    private var snapshot: ProviderSnapshot? { store.snapshot(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(provider.displayName).font(.title3.weight(.semibold))

            // Provider switcher
            HStack(spacing: 6) {
                ForEach(ProviderID.allCases.filter { settings.enabledProviders.contains($0) }) { id in
                    Button(id.shortLabel) {
                        settings.selectedProvider = id
                    }
                    .buttonStyle(.bordered)
                }
            }

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
            } else if store.isRefreshing {
                Text("Loading…").foregroundStyle(.secondary)
            } else {
                Text("No usage yet").foregroundStyle(.secondary)
                if let err = store.lastGlobalError {
                    Text(err).font(.caption).foregroundColor(.orange)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Providers").font(.caption).foregroundStyle(.secondary)
                ForEach(ProviderID.allCases) { id in
                    Toggle(id.displayName, isOn: Binding(
                        get: { settings.enabledProviders.contains(id) },
                        set: { on in settings.setProvider(id, enabled: on) }))
                }
            }

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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(minWidth: 260, alignment: .leading)
    }
}

struct IconView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settings: SettingsStore

    var body: some View {
        let id = settings.selectedProvider
        let snap = store.snapshot(for: id)
        let stale = snap?.error != nil
        if let snap, !snap.windows.isEmpty {
            Image(nsImage: IconRenderer.makeIcon(
                primaryRemaining: snap.primaryRemaining,
                weeklyRemaining: snap.secondaryRemaining,
                stale: stale,
                badge: id.shortLabel))
        } else {
            Image(systemName: "chart.bar.fill")
        }
    }
}

// MARK: - App

@main
struct CodexBarApp: App {
    @StateObject private var settings: SettingsStore
    @StateObject private var store: UsageStore

    init() {
        // Single SettingsStore instance shared by both StateObjects.
        let settings = SettingsStore()
        _settings = StateObject(wrappedValue: settings)
        _store = StateObject(wrappedValue: UsageStore(settings: settings))
    }

    var body: some Scene {
        // One MenuBarExtra only. Multiple extras + isInserted bindings hung
        // the main thread in SwiftUI AttributeGraph on macOS 13.
        MenuBarExtra {
            MenuContent(store: store, settings: settings)
        } label: {
            IconView(store: store, settings: settings)
        }
    }
}

@MainActor
private func showAbout() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .informational
    alert.messageText = "CodexBar 0.2.5 (macOS 13)"
    alert.informativeText = """
    Multi-provider fork for Intel macOS 13.
    Providers: Codex · Claude · OpenRouter · Grok
    Based on steipete/CodexBar (MIT)
    """
    alert.icon = NSApplication.shared.applicationIconImage
    alert.addButton(withTitle: "OK")
    alert.runModal()
}
