import Foundation

enum GrokUsageFetcher {
    /// Modern CodexBar prefers CLI billing + browser cookies. On macOS 13 we surface
    /// identity from `~/.grok/auth.json` plus local session token signals when present.
    static func loadUsage(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ProviderSnapshot
    {
        let home = environment["GROK_HOME"] ?? "\(NSHomeDirectory())/.grok"
        let grokHome = URL(fileURLWithPath: home)
        let auth = loadAuthIdentity(grokHome: grokHome)
        let signal = loadLocalSignalSummary(grokHome: grokHome, fileManager: fileManager)

        var details: [String] = []
        if let mode = auth.authMode { details.append("Mode: \(mode)") }
        if let tokens = signal.totalTokens {
            details.append("Local session tokens (30d): \(tokens)")
        }
        if let models = signal.models, !models.isEmpty {
            details.append("Models: \(models.prefix(4).joined(separator: ", "))")
        }
        if signal.sessionCount > 0 {
            details.append("Sessions seen: \(signal.sessionCount)")
        }
        details.append("Billing % needs grok.com/session (full app on macOS 14+).")

        // Represent remaining as unknown/full when we only have identity.
        let used = signal.usedPercentHint ?? 0
        let windows = [
            NamedWindow(
                id: "local",
                title: "Local signal",
                window: RateWindow(usedPercent: used, windowMinutes: nil, resetsAt: nil)),
        ]

        var accountParts: [String] = []
        if let email = auth.email { accountParts.append(email) }
        if let plan = auth.authMode { accountParts.append(plan) }

        if auth.email == nil && signal.sessionCount == 0 {
            throw UsageError.missingCredentials(
                "No ~/.grok/auth.json or local Grok sessions. Run `grok login` / use Grok CLI.")
        }

        return ProviderSnapshot(
            id: .grok,
            windows: windows,
            accountLine: accountParts.isEmpty ? "Grok local" : accountParts.joined(separator: " · "),
            detailLines: details,
            updatedAt: signal.updatedAt ?? Date(),
            error: nil)
    }

    private static func loadAuthIdentity(grokHome: URL) -> (email: String?, authMode: String?) {
        let authURL = grokHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data)
        else {
            return (nil, nil)
        }

        // auth.json can be a dictionary of OIDC entries or a flatter shape.
        if let dict = root as? [String: Any] {
            if let email = dict["email"] as? String {
                return (email, dict["auth_mode"] as? String)
            }
            for (_, value) in dict {
                guard let entry = value as? [String: Any] else { continue }
                if let email = entry["email"] as? String {
                    return (email, entry["auth_mode"] as? String)
                }
            }
        }
        return (nil, nil)
    }

    private static func loadLocalSignalSummary(
        grokHome: URL,
        fileManager: FileManager) -> (totalTokens: Int?, models: [String]?, sessionCount: Int, usedPercentHint: Double?, updatedAt: Date?)
    {
        let sessions = grokHome.appendingPathComponent("sessions")
        guard let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])
        else {
            return (nil, nil, 0, nil, nil)
        }

        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var totalTokens = 0
        var models = Set<String>()
        var count = 0
        var newest: Date?

        for case let url as URL in enumerator where url.lastPathComponent == "signals.json" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate,
                  mtime >= cutoff
            else { continue }

            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            count += 1
            if let current = newest {
                newest = current > mtime ? current : mtime
            } else {
                newest = mtime
            }
            if let t = json["totalTokensBeforeCompaction"] as? Int {
                totalTokens += t
            } else if let t = json["contextTokensUsed"] as? Int {
                totalTokens += t
            }
            if let arr = json["modelsUsed"] as? [String] {
                models.formUnion(arr)
            }
        }

        return (
            totalTokens > 0 ? totalTokens : nil,
            models.isEmpty ? nil : Array(models).sorted(),
            count,
            nil,
            newest)
    }
}
