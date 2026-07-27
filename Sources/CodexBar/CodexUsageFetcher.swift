import Foundation

enum CodexUsageFetcher {
    static func loadLatestUsage(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> ProviderSnapshot
    {
        let home = environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
        let codexHome = URL(fileURLWithPath: home)
        let sessionFile = try latestSessionFile(codexHome: codexHome, fileManager: fileManager)
        let lines = try readTailLines(url: sessionFile, maxBytes: 512_000, fileManager: fileManager)

        // Walk newest → oldest for the latest token_count with rate_limits.
        for line in lines.reversed() {
            guard let limits = parseRateLimits(fromLine: line) else { continue }

            let account = loadAccountInfo(codexHome: codexHome)
            var accountParts: [String] = []
            if let email = account.email { accountParts.append(email) }
            if let plan = limits.planType ?? account.plan {
                accountParts.append(plan.capitalized)
            }

            var windows: [NamedWindow] = []
            if let primary = limits.primary {
                windows.append(NamedWindow(
                    id: "primary",
                    title: windowTitle(primary, fallback: "Primary limit"),
                    window: primary.rateWindow))
            }
            if let secondary = limits.secondary {
                windows.append(NamedWindow(
                    id: "secondary",
                    title: windowTitle(secondary, fallback: "Secondary limit"),
                    window: secondary.rateWindow))
            }

            var details: [String] = []
            if let credits = limits.creditsBalance {
                details.append("Credits: \(credits)")
            }
            if let limitID = limits.limitID {
                details.append("Limit: \(limitID)")
            }

            guard !windows.isEmpty else { continue }

            return ProviderSnapshot(
                id: .codex,
                windows: windows,
                accountLine: accountParts.isEmpty ? nil : accountParts.joined(separator: " · "),
                detailLines: details,
                updatedAt: limits.updatedAt ?? Date(),
                error: nil)
        }

        throw UsageError.noRateLimitsFound
    }

    private static func windowTitle(_ window: Window, fallback: String) -> String {
        guard let minutes = window.windowMinutes else { return fallback }
        switch minutes {
        case 0 ..< 60:
            return "\(minutes)m limit"
        case 60 ..< 24 * 60:
            let hours = minutes / 60
            return "\(hours)h limit"
        case 24 * 60 ..< 8 * 24 * 60:
            let days = minutes / (24 * 60)
            return days == 7 ? "Weekly limit" : "\(days)d limit"
        default:
            let days = minutes / (24 * 60)
            return "\(days)d limit"
        }
    }

    private static func parseRateLimits(fromLine line: String) -> ParsedLimits? {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Common shapes:
        // 1) { timestamp, type:event_msg, payload:{ type:token_count, rate_limits:{...} } }
        // 2) { timestamp, payload:{ type:token_count, rate_limits:{...} } }
        let payload = (root["payload"] as? [String: Any]) ?? root
        let type = payload["type"] as? String
        guard type == "token_count" || type == "event_msg" else {
            // Some lines nest type under payload only; already handled.
            // Accept payload.rate_limits even if type missing when rate_limits present.
            if payload["rate_limits"] == nil { return nil }
            // continue
            _ = type
        }

        // If outer type is event_msg, real type is payload.type
        if type == "event_msg" {
            // shouldn't happen with assignment above; keep for safety
        }
        let effectiveType = (payload["type"] as? String) ?? type
        guard effectiveType == "token_count" || payload["rate_limits"] != nil else { return nil }

        guard let rate = payload["rate_limits"] as? [String: Any] else { return nil }

        let primary = parseWindow(rate["primary"])
        let secondary = parseWindow(rate["secondary"])
        guard primary != nil || secondary != nil else { return nil }

        let planType = rate["plan_type"] as? String
        let limitID = rate["limit_id"] as? String
        var creditsBalance: String?
        if let credits = rate["credits"] as? [String: Any] {
            if let balance = credits["balance"] as? String {
                creditsBalance = balance
            } else if let balance = credits["balance"] as? NSNumber {
                creditsBalance = balance.stringValue
            }
        }

        let updatedAt = parseTimestamp(root["timestamp"]) ?? parseTimestamp(payload["timestamp"])

        return ParsedLimits(
            primary: primary,
            secondary: secondary,
            planType: planType,
            limitID: limitID,
            creditsBalance: creditsBalance,
            updatedAt: updatedAt)
    }

    private static func parseWindow(_ any: Any?) -> Window? {
        guard let dict = any as? [String: Any] else { return nil }
        let used: Double?
        if let d = dict["used_percent"] as? Double {
            used = d
        } else if let n = dict["used_percent"] as? NSNumber {
            used = n.doubleValue
        } else if let s = dict["used_percent"] as? String {
            used = Double(s)
        } else {
            used = nil
        }
        guard let usedPercent = used else { return nil }

        let minutes: Int?
        if let i = dict["window_minutes"] as? Int {
            minutes = i
        } else if let n = dict["window_minutes"] as? NSNumber {
            minutes = n.intValue
        } else {
            minutes = nil
        }

        let resets: TimeInterval?
        if let d = dict["resets_at"] as? Double {
            resets = d
        } else if let i = dict["resets_at"] as? Int {
            resets = TimeInterval(i)
        } else if let n = dict["resets_at"] as? NSNumber {
            resets = n.doubleValue
        } else {
            resets = nil
        }

        return Window(usedPercent: usedPercent, windowMinutes: minutes, resetsAt: resets)
    }

    private static func parseTimestamp(_ any: Any?) -> Date? {
        if let s = any as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = fractional.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }
        if let d = any as? Double {
            return Date(timeIntervalSince1970: d)
        }
        if let n = any as? NSNumber {
            return Date(timeIntervalSince1970: n.doubleValue)
        }
        return nil
    }

    private static func readTailLines(url: URL, maxBytes: Int, fileManager: FileManager) throws -> [String] {
        let attrs = try fileManager.attributesOfItem(atPath: url.path)
        let fileSize = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        if fileSize > maxBytes {
            try handle.seek(toOffset: UInt64(fileSize - maxBytes))
        }
        let data = handle.readDataToEndOfFile()
        guard var text = String(data: data, encoding: .utf8) else {
            throw UsageError.decodeFailed
        }
        // If we started mid-line, drop the partial first line.
        if fileSize > maxBytes, let nl = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: nl)...])
        }
        return text.split(whereSeparator: \.isNewline).map(String.init)
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

private struct ParsedLimits {
    let primary: Window?
    let secondary: Window?
    let planType: String?
    let limitID: String?
    let creditsBalance: String?
    let updatedAt: Date?
}

private struct Window {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: TimeInterval?

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
