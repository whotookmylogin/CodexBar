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
        request.timeoutInterval = 45
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        let session = URLSession(configuration: {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 45
            config.timeoutIntervalForResource = 60
            config.waitsForConnectivity = true
            return config
        }())

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // One retry on cancellation/transient failures (menu-bar cold start race).
            try await Task.sleep(nanoseconds: 400_000_000)
            (data, response) = try await session.data(for: request)
        } finally {
            session.finishTasksAndInvalidate()
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("Claude OAuth: invalid response")
        }

        switch http.statusCode {
        case 200:
            break
        case 401:
            throw UsageError.unauthorized("Claude OAuth unauthorized. Run `claude auth login`.")
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
            if let used = extra.usedValue, let limit = extra.limitValue {
                details.append(String(format: "Extra usage: $%.2f / $%.2f", used, limit))
            } else if let used = extra.usedValue {
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
        let path = environment["CLAUDE_CREDENTIALS"] ?? "\(home)/.claude/.credentials.json"
        let url = URL(fileURLWithPath: path)

        if let data = try? Data(contentsOf: url),
           let token = extractToken(from: data)
        {
            return token
        }

        // Claude Code on macOS often stores OAuth in Keychain only.
        if let data = readKeychainCredentials(),
           let token = extractToken(from: data)
        {
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: home).appendingPathComponent(".claude"),
                withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            return token
        }

        throw UsageError.missingCredentials(
            "Missing Claude OAuth credentials. Run `claude auth login` in Terminal.")
    }

    private static func extractToken(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
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
        return nil
    }

    private static func readKeychainCredentials() -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = [
            "find-generic-password",
            "-a", NSUserName(),
            "-s", "Claude Code-credentials",
            "-w",
        ]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return nil
        }
        guard proc.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else { return nil }

        if raw.hasPrefix("{") {
            return raw.data(using: .utf8)
        }

        let hex = raw.replacingOccurrences(of: " ", with: "")
        let hexSet = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        if hex.count % 2 == 0, hex.unicodeScalars.allSatisfy({ hexSet.contains($0) }) {
            var bytes = [UInt8]()
            bytes.reserveCapacity(hex.count / 2)
            var idx = hex.startIndex
            while idx < hex.endIndex {
                let next = hex.index(idx, offsetBy: 2)
                if let b = UInt8(hex[idx..<next], radix: 16) {
                    bytes.append(b)
                } else {
                    return raw.data(using: .utf8)
                }
                idx = next
            }
            return Data(bytes)
        }
        return raw.data(using: .utf8)
    }

    private static func stringValue(_ any: Any?) -> String? {
        if let s = any as? String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        if let n = any as? NSNumber { return n.stringValue }
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
        // Claude OAuth usage returns utilization as a percent (e.g. 1.0 = 1%, 4.0 = 4%).
        let used = usedPercent ?? utilization
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
    let usedCredits: Double?
    let monthlyLimit: Double?
    let isEnabled: Bool?

    enum CodingKeys: String, CodingKey {
        case used
        case limit
        case usedCredits = "used_credits"
        case monthlyLimit = "monthly_limit"
        case isEnabled = "is_enabled"
    }

    var usedValue: Double? { used ?? usedCredits }
    var limitValue: Double? { limit ?? monthlyLimit }
}

private func parseISO8601(_ string: String?) -> Date? {
    guard let string, !string.isEmpty else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
}
