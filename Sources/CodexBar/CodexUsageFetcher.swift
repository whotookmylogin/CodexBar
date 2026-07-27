import Foundation

enum CodexUsageFetcher {
    static func loadLatestUsage(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ProviderSnapshot
    {
        let home = environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
        let codexHome = URL(fileURLWithPath: home)
        let sessionFile = try latestSessionFile(codexHome: codexHome, fileManager: fileManager)
        let lines = try String(contentsOf: sessionFile, encoding: .utf8).split(whereSeparator: \.isNewline)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for lineSub in lines.reversed() {
            guard let data = lineSub.data(using: .utf8) else { continue }
            guard let event = try? decoder.decode(SessionLine.self, from: data) else { continue }
            guard event.payload?.type == "token_count", let limits = event.payload?.rateLimits else { continue }

            let account = loadAccountInfo(codexHome: codexHome)
            var accountParts: [String] = []
            if let email = account.email { accountParts.append(email) }
            if let plan = account.plan { accountParts.append(plan.capitalized) }

            return ProviderSnapshot(
                id: .codex,
                windows: [
                    NamedWindow(id: "primary", title: "5h limit", window: limits.primary.rateWindow),
                    NamedWindow(id: "weekly", title: "Weekly limit", window: limits.secondary.rateWindow),
                ],
                accountLine: accountParts.isEmpty ? nil : accountParts.joined(separator: " · "),
                detailLines: [],
                updatedAt: event.timestamp ?? Date(),
                error: nil)
        }

        throw UsageError.noRateLimitsFound
    }

    private static func loadAccountInfo(codexHome: URL) -> (email: String?, plan: String?) {
        let authURL = codexHome.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let auth = try? JSONDecoder().decode(AuthFile.self, from: data),
              let idToken = auth.tokens?.idToken,
              let payload = parseJWT(idToken)
        else {
            return (nil, nil)
        }

        let authDict = payload["https://api.openai.com/auth"] as? [String: Any]
        let profileDict = payload["https://api.openai.com/profile"] as? [String: Any]
        let plan = (authDict?["chatgpt_plan_type"] as? String)
            ?? (payload["chatgpt_plan_type"] as? String)
        let email = (payload["email"] as? String)
            ?? (profileDict?["email"] as? String)
        return (email, plan)
    }

    private static func latestSessionFile(codexHome: URL, fileManager: FileManager) throws -> URL {
        let sessions = codexHome.appendingPathComponent("sessions")
        guard let enumerator = fileManager.enumerator(
            at: sessions,
            includingPropertiesForKeys: [.contentModificationDateKey])
        else {
            throw UsageError.noSessions
        }

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.lastPathComponent.hasPrefix("rollout-") {
            guard let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { continue }
            if newest == nil || date > newest!.date { newest = (url, date) }
        }

        guard let found = newest else { throw UsageError.noSessions }
        return found.url
    }

    private static func parseJWT(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var padded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while padded.count % 4 != 0 { padded.append("=") }
        guard let data = Data(base64Encoded: padded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }
}

private struct SessionLine: Decodable {
    let timestamp: Date?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
        let rateLimits: RateLimits?

        enum CodingKeys: String, CodingKey {
            case type
            case rateLimits = "rate_limits"
        }
    }
}

private struct RateLimits: Decodable {
    let primary: Window
    let secondary: Window
}

private struct Window: Decodable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }

    var rateWindow: RateWindow {
        RateWindow(
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetsAt.map { Date(timeIntervalSince1970: $0) })
    }
}

private struct AuthFile: Decodable {
    let tokens: Tokens?
}

private struct Tokens: Decodable {
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
    }
}
