import Foundation

enum OpenRouterUsageFetcher {
    static func loadUsage(
        environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> ProviderSnapshot
    {
        let apiKey = try resolveAPIKey(environment: environment)
        let base = (environment["OPENROUTER_API_URL"] ?? "https://openrouter.ai/api/v1")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        async let creditsData = getJSON(urlString: "\(base)/credits", apiKey: apiKey)
        async let keyData = getJSON(urlString: "\(base)/key", apiKey: apiKey)

        let creditsJSON = try await creditsData
        let keyJSON = try? await keyData

        let creditsRoot = (creditsJSON["data"] as? [String: Any]) ?? creditsJSON
        let totalCredits = doubleValue(creditsRoot["total_credits"]) ?? 0
        let totalUsage = doubleValue(creditsRoot["total_usage"]) ?? 0
        let balance = max(0, totalCredits - totalUsage)
        let usedPercent: Double = {
            guard totalCredits > 0 else { return 0 }
            return min(100, (totalUsage / totalCredits) * 100)
        }()

        var windows: [NamedWindow] = [
            NamedWindow(
                id: "credits",
                title: "Credits used",
                window: RateWindow(usedPercent: usedPercent, windowMinutes: nil, resetsAt: nil)),
        ]

        var details: [String] = [
            String(format: "Balance: $%.2f", balance),
            String(format: "Lifetime $%.2f / $%.2f", totalUsage, totalCredits),
        ]

        if let keyJSON {
            let keyRoot = (keyJSON["data"] as? [String: Any]) ?? keyJSON
            if let limit = doubleValue(keyRoot["limit"]), limit > 0,
               let usage = doubleValue(keyRoot["usage"])
            {
                let keyUsed = min(100, (usage / limit) * 100)
                windows.insert(
                    NamedWindow(
                        id: "key_limit",
                        title: "Key limit",
                        window: RateWindow(usedPercent: keyUsed, windowMinutes: nil, resetsAt: nil)),
                    at: 0)
                details.append(String(format: "Key: $%.2f / $%.2f", usage, limit))
            }
            if let daily = doubleValue(keyRoot["usage_daily"]) {
                details.append(String(format: "Today: $%.2f", daily))
            }
            if let weekly = doubleValue(keyRoot["usage_weekly"]) {
                details.append(String(format: "Week: $%.2f", weekly))
            }
            if let monthly = doubleValue(keyRoot["usage_monthly"]) {
                details.append(String(format: "Month: $%.2f", monthly))
            }
        }

        return ProviderSnapshot(
            id: .openrouter,
            windows: windows,
            accountLine: "OpenRouter API key",
            detailLines: details,
            updatedAt: Date(),
            error: nil)
    }

    private static func resolveAPIKey(environment: [String: String]) throws -> String {
        if let env = environment["OPENROUTER_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return env
        }

        // Optional local config used by modern CodexBar.
        let home = environment["HOME"] ?? NSHomeDirectory()
        for relative in [".config/codexbar/config.json", ".codexbar/config.json"] {
            let url = URL(fileURLWithPath: home).appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            if let providers = json["providers"] as? [String: Any],
               let openrouter = providers["openrouter"] as? [String: Any],
               let key = openrouter["apiKey"] as? String ?? openrouter["api_key"] as? String
            {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let key = json["openrouterApiKey"] as? String {
                let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        throw UsageError.missingCredentials(
            "Set OPENROUTER_API_KEY or add openrouter apiKey to ~/.config/codexbar/config.json")
    }

    private static func getJSON(urlString: String, apiKey: String) async throws -> [String: Any] {
        guard let url = URL(string: urlString) else { throw UsageError.decodeFailed }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBar", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/steipete/CodexBar", forHTTPHeaderField: "HTTP-Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("OpenRouter invalid response")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 {
                throw UsageError.unauthorized("OpenRouter unauthorized.")
            }
            throw UsageError.network("OpenRouter HTTP \(http.statusCode): \(body.prefix(160))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.decodeFailed
        }
        return json
    }

    private static func doubleValue(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
