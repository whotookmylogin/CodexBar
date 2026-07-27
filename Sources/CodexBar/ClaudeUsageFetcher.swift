import Foundation

enum ClaudeUsageFetcher {
    static func loadUsage(
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ProviderSnapshot
    {
        let token = try loadAccessToken(environment: environment)
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
            throw UsageError.decodeFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("Claude OAuth: invalid response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw UsageError.unauthorized("Claude OAuth unauthorized. Run `claude login`.")
        case 429:
            throw UsageError.network("Claude OAuth rate limited. Wait a few minutes, then refresh.")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageError.network("Claude OAuth HTTP \(http.statusCode): \(body.prefix(200))")
        }

        let decoded = try JSONDecoder().decode(OAuthUsageResponse.self, from: data)
        var windows: [NamedWindow] = []

        if let five = decoded.fiveHour?.asRateWindow() {
            windows.append(NamedWindow(id: "five_hour", title: "5h limit", window: five))
        }
        if let week = decoded.sevenDay?.asRateWindow() {
            windows.append(NamedWindow(id: "seven_day", title: "Weekly limit", window: week))
        }
        if let sonnet = decoded.sevenDaySonnet?.asRateWindow() {
            windows.append(NamedWindow(id: "sonnet", title: "Sonnet weekly", window: sonnet))
        }
        if let opus = decoded.sevenDayOpus?.asRateWindow() {
            windows.append(NamedWindow(id: "opus", title: "Opus weekly", window: opus))
        }

        if windows.isEmpty {
            throw UsageError.noRateLimitsFound
        }

        var details: [String] = []
        if let extra = decoded.extraUsage {
            if let used = extra.used, let limit = extra.limit {
                details.append(String(format: "Extra usage: $%.2f / $%.2f", used, limit))
            } else if let used = extra.used {
                details.append(String(format: "Extra usage: $%.2f", used))
            }
        }

        return ProviderSnapshot(
            id: .claude,
            windows: windows,
            accountLine: "Claude Code OAuth",
            detailLines: details,
            updatedAt: Date(),
            error: nil)
    }

    private static func loadAccessToken(environment: [String: String]) throws -> String {
        let home = environment["HOME"] ?? NSHomeDirectory()
        let path = (environment["CLAUDE_CREDENTIALS"] as String?)
            ?? "\(home)/.claude/.credentials.json"
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw UsageError.missingCredentials(
                "Missing ~/.claude/.credentials.json. Run `claude login`.")
        }

        if let oauth = root["claudeAiOauth"] as? [String: Any] {
            if let token = stringValue(oauth["accessToken"]) ?? stringValue(oauth["access_token"]),
               !token.isEmpty
            {
                return token
            }
        }

        if let token = stringValue(root["accessToken"]) ?? stringValue(root["access_token"]),
           !token.isEmpty
        {
            return token
        }

        if root["mcpOAuth"] != nil {
            throw UsageError.missingCredentials(
                "Claude credentials are MCP-only. Re-run `claude login` for usage OAuth.")
        }

        throw UsageError.missingCredentials(
            "No Claude OAuth access token found in credentials file.")
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        return nil
    }
}

private struct OAuthUsageResponse: Decodable {
    let fiveHour: OAuthUsageWindow?
    let sevenDay: OAuthUsageWindow?
    let sevenDayOpus: OAuthUsageWindow?
    let sevenDaySonnet: OAuthUsageWindow?
    let extraUsage: OAuthExtraUsage?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case extraUsage = "extra_usage"
    }
}

private struct OAuthUsageWindow: Decodable {
    let utilization: Double?
    let usedPercent: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }

    func asRateWindow() -> RateWindow? {
        let used = usedPercent ?? utilization.map { $0 <= 1.0 ? $0 * 100.0 : $0 }
        guard let used else { return nil }
        return RateWindow(
            usedPercent: used,
            windowMinutes: nil,
            resetsAt: parseISO8601(resetsAt))
    }
}

private struct OAuthExtraUsage: Decodable {
    let used: Double?
    let limit: Double?
}

private func parseISO8601(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}
