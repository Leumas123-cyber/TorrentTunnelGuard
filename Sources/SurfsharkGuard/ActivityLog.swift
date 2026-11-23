import Foundation

/// One line in the history: when the tunnel changed, or what the app did.
struct ActivityEntry: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case tunnel   // tunnel appeared, vanished, or moved to another utun
        case status   // protection state changed (ok / wrong binding / no tunnel)
        case action   // something the app did (fix, pause, quit qBittorrent)
        case problem  // an error the app ran into

        var symbolName: String {
            switch self {
            case .tunnel: return "network"
            case .status: return "shield.lefthalf.filled"
            case .action: return "checkmark.circle"
            case .problem: return "exclamationmark.triangle"
            }
        }
    }

    var id = UUID()
    var date: Date
    var kind: Kind
    var message: String
}

/// Small, size-capped history, oldest first. Pure value type so it is easy to test.
struct ActivityLog: Equatable {
    static let defaultLimit = 200

    private(set) var entries: [ActivityEntry]
    let limit: Int

    init(entries: [ActivityEntry] = [], limit: Int = ActivityLog.defaultLimit) {
        self.limit = max(1, limit)
        self.entries = Array(entries.suffix(self.limit))
    }

    /// Adds an entry. A repeat of the newest message is skipped so a problem
    /// that persists across watch ticks does not flood the history.
    /// Returns true when the entry was stored.
    @discardableResult
    mutating func append(_ kind: ActivityEntry.Kind, _ message: String,
                         at date: Date = Date()) -> Bool {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let last = entries.last, last.kind == kind, last.message == text {
            return false
        }
        entries.append(ActivityEntry(date: date, kind: kind, message: text))
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
        return true
    }

    mutating func clear() {
        entries.removeAll()
    }

    /// Newest first, for display.
    var newestFirst: [ActivityEntry] { entries.reversed() }

    func encoded() -> Data? {
        try? JSONEncoder().encode(entries)
    }

    static func decode(_ data: Data?, limit: Int = ActivityLog.defaultLimit) -> ActivityLog {
        guard let data,
              let entries = try? JSONDecoder().decode([ActivityEntry].self, from: data)
        else { return ActivityLog(limit: limit) }
        return ActivityLog(entries: entries, limit: limit)
    }
}

/// Text for a tunnel change between two checks, or nil when nothing changed.
/// `nil` interface means "no tunnel".
func tunnelChangeMessage(previousIface: String?, previousIP: String?,
                         currentIface: String?, currentIP: String?,
                         firstCheck: Bool) -> String? {
    func describe(_ iface: String, _ ip: String?) -> String {
        if let ip, !ip.isEmpty { return "\(iface) (\(ip))" }
        return iface
    }
    if firstCheck {
        guard let currentIface else { return "Started — no VPN tunnel" }
        return "Started — tunnel is \(describe(currentIface, currentIP))"
    }
    switch (previousIface, currentIface) {
    case (nil, nil):
        return nil
    case (nil, let now?):
        return "Tunnel up: \(describe(now, currentIP))"
    case (let before?, nil):
        return "Tunnel down (was \(before))"
    case (let before?, let now?):
        if before != now {
            return "Tunnel moved: \(describe(before, previousIP)) → \(describe(now, currentIP))"
        }
        if let previousIP, let currentIP, previousIP != currentIP {
            return "Tunnel IP changed on \(now): \(previousIP) → \(currentIP)"
        }
        return nil
    }
}
