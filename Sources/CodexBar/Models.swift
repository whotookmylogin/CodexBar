import Foundation

struct RateWindow: Equatable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    var resetCountdown: String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSinceNow
        if seconds <= 0 { return "reset due" }
        let mins = Int(seconds / 60)
        if mins < 60 { return "resets in \(mins)m" }
        let hours = mins / 60
        let rem = mins % 60
        if hours < 48 { return "resets in \(hours)h \(rem)m" }
        let days = hours / 24
        return "resets in \(days)d"
    }
}

struct NamedWindow: Identifiable, Equatable {
    let id: String
    let title: String
    let window: RateWindow
}

enum ProviderID: String, CaseIterable, Identifiable, Codable {
    case codex
    case claude
    case openrouter
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .openrouter: return "OpenRouter"
        case .grok: return "Grok"
        }
    }

    var shortLabel: String {
        switch self {
        case .codex: return "Cx"
        case .claude: return "Cl"
        case .openrouter: return "OR"
        case .grok: return "Gk"
        }
    }
}

struct ProviderSnapshot: Equatable {
    let id: ProviderID
    let windows: [NamedWindow]
    let accountLine: String?
    let detailLines: [String]
    let updatedAt: Date
    let error: String?

    var primaryRemaining: Double? { windows.first?.window.remainingPercent }
    var secondaryRemaining: Double? {
        windows.count > 1 ? windows[1].window.remainingPercent : nil
    }

    var lowestRemaining: Double? {
        let values = windows.map(\.window.remainingPercent)
        return values.min()
    }
}

enum UsageError: LocalizedError {
    case noSessions
    case noRateLimitsFound
    case decodeFailed
    case missingCredentials(String)
    case network(String)
    case unauthorized(String)

    var errorDescription: String? {
        switch self {
        case .noSessions:
            return "No Codex sessions found yet. Run at least one Codex prompt first."
        case .noRateLimitsFound:
            return "Found sessions, but no rate limit events yet."
        case .decodeFailed:
            return "Could not parse usage data."
        case let .missingCredentials(msg):
            return msg
        case let .network(msg):
            return msg
        case let .unauthorized(msg):
            return msg
        }
    }
}
