import Foundation

/// The torrent app the guard keeps on the tunnel.
enum TorrentClient: String, CaseIterable, Identifiable {
    case qbittorrent
    case transmission
    case deluge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .qbittorrent: return "qBittorrent"
        case .transmission: return "Transmission"
        case .deluge: return "Deluge"
        }
    }

    /// Short name for tight spots such as the menu-bar tooltip.
    var shortName: String {
        switch self {
        case .qbittorrent: return "qB"
        case .transmission: return "Transmission"
        case .deluge: return "Deluge"
        }
    }

    /// What the remote control is called in the client's own preferences.
    var remoteTitle: String {
        switch self {
        case .qbittorrent: return "Web UI"
        case .transmission: return "Remote (RPC)"
        case .deluge: return "Web UI"
        }
    }

    var defaultRemoteURL: String {
        switch self {
        case .qbittorrent: return "http://127.0.0.1:8080"
        case .transmission: return "http://127.0.0.1:9091/transmission/rpc"
        case .deluge: return "http://127.0.0.1:8112"
        }
    }

    /// qBittorrent needs a user name; Transmission auth is optional;
    /// Deluge's Web UI only has a password.
    var usesUserName: Bool { self != .deluge }

    func credentialsReady(user: String, password: String) -> Bool {
        switch self {
        case .qbittorrent: return !user.isEmpty
        case .transmission: return true
        case .deluge: return !password.isEmpty
        }
    }

    /// Can the remote API change the binding while the client keeps running?
    /// Transmission's RPC has no bind-address setting, so it needs a restart.
    var supportsLiveRebind: Bool { self != .transmission }

    /// UserDefaults key for a per-client remote setting. qBittorrent keeps the
    /// original keys so existing installs carry over unchanged.
    func defaultsKey(_ base: String) -> String {
        self == .qbittorrent ? base : "\(rawValue).\(base)"
    }

    /// Keychain account for the remote password (same service for all).
    var keychainAccount: String {
        self == .qbittorrent ? KeychainStore.account : rawValue
    }

    /// Lowercased `pgrep -ifl` needles for a running client.
    var processNeedles: [String] {
        switch self {
        case .qbittorrent: return ["qbittorrent"]
        case .transmission: return ["transmission"]
        case .deluge: return ["deluge"]
        }
    }

    /// True for a `pgrep -ifl` line that is this client holding the session.
    /// `deluge-web` alone does not own core.conf, so it does not count.
    func matchesProcessLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        guard processNeedles.contains(where: { lower.contains($0) }),
              !lower.contains("surfshark") else { return false }
        if self == .deluge, lower.contains("deluge-web"),
           !lower.contains("deluged") {
            return false
        }
        return true
    }

    func matchesApp(bundleID: String?, name: String?) -> Bool {
        let bundle = bundleID?.lowercased() ?? ""
        let label = name?.lowercased() ?? ""
        if bundle.contains("surfshark") { return false }
        switch self {
        case .qbittorrent:
            return bundle.contains("qbittorrent") || label.contains("qbittorrent")
        case .transmission:
            return bundle == "org.m0k.transmission" || label == "transmission"
        case .deluge:
            return bundle.contains("deluge") || label.contains("deluge")
        }
    }
}

// MARK: - Binding helpers shared by Transmission and Deluge

enum ClientBinding {
    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy(\.isNumber), let value = Int(part) else { return false }
            return value <= 255
        }
    }

    static func isUnbound(_ address: String?) -> Bool {
        guard let address = address?.trimmingCharacters(in: .whitespaces),
              !address.isEmpty else { return true }
        return address == "0.0.0.0" || address == "::" || address == "*"
    }

    static func interface(owning ip: String, in ifaces: [String: IfInfo]) -> String? {
        ifaces.filter { $0.value.ipv4 == ip }.keys.sorted().first
    }

    /// Transmission binds by IPv4 address only. The interface is whichever
    /// one currently holds that address, so a stale tunnel IP shows as unbound.
    static func transmission(bindAddress: String?,
                             ifaces: [String: IfInfo]) -> (iface: String?, addr: String?) {
        guard let bindAddress, !isUnbound(bindAddress) else {
            return (nil, "0.0.0.0")
        }
        return (interface(owning: bindAddress, in: ifaces), bindAddress)
    }

    /// Deluge: `outgoing_interface` (name or IP) carries the peer traffic,
    /// `listen_interface` (IP) takes incoming peers. Empty listen means all
    /// interfaces, which is reported as 0.0.0.0 so it never counts as sealed.
    static func deluge(outgoing: String?, listen: String?,
                       ifaces: [String: IfInfo]) -> (iface: String?, addr: String?) {
        let out = outgoing?.trimmingCharacters(in: .whitespaces) ?? ""
        let lis = listen?.trimmingCharacters(in: .whitespaces) ?? ""

        var iface: String?
        if isUnbound(out) {
            iface = nil
        } else if isIPv4(out) {
            iface = interface(owning: out, in: ifaces)
        } else {
            iface = out
        }

        var addr: String
        if isUnbound(lis) {
            addr = "0.0.0.0"
        } else if isIPv4(lis) {
            addr = lis
        } else {
            addr = ifaces[lis]?.ipv4 ?? lis
        }
        return (iface, addr)
    }
}

// MARK: - Minimal text editing for JSON config files

/// Edits single string values in a JSON config without re-serialising the
/// whole file, so numbers, key order and the client's own formatting survive.
/// Deluge's core.conf is two JSON objects back to back; keys are looked up
/// and inserted in the last top-level object.
enum JSONConfigText {
    private static func pattern(for key: String) -> NSRegularExpression? {
        let escaped = NSRegularExpression.escapedPattern(for: key)
        return try? NSRegularExpression(
            pattern: "\"\(escaped)\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|null)")
    }

    private static func lastObjectRange(in text: String) -> NSRange? {
        guard let opening = topLevelObjectOpenings(in: text).last else { return nil }
        let ns = text as NSString
        return NSRange(location: opening, length: ns.length - opening)
    }

    /// UTF-16 offsets of every `{` that opens a top-level object.
    static func topLevelObjectOpenings(in text: String) -> [Int] {
        var result: [Int] = []
        var depth = 0
        var inString = false
        var escaped = false
        for (offset, unit) in text.utf16.enumerated() {
            if inString {
                if escaped { escaped = false }
                else if unit == 0x5C { escaped = true }        // backslash
                else if unit == 0x22 { inString = false }      // quote
                continue
            }
            switch unit {
            case 0x22: inString = true
            case 0x7B:                                          // {
                if depth == 0 { result.append(offset) }
                depth += 1
            case 0x7D: depth = max(0, depth - 1)                // }
            default: break
            }
        }
        return result
    }

    static func stringValue(_ key: String, in text: String) -> String? {
        guard let regex = pattern(for: key),
              let scope = lastObjectRange(in: text),
              let match = regex.firstMatch(in: text, options: [], range: scope) else { return nil }
        let raw = (text as NSString).substring(with: match.range(at: 1))
        if raw == "null" { return nil }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(
                with: data, options: .fragmentsAllowed) as? String
        else { return nil }
        return value
    }

    static func jsonQuoted(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// Sets `key` to a string value. A missing key is added at the top of the
    /// last object; text without any object becomes a fresh one.
    static func setting(_ key: String, to value: String, in text: String) -> String {
        let quoted = jsonQuoted(value)
        guard let regex = pattern(for: key), let scope = lastObjectRange(in: text) else {
            return "{\n    \(jsonQuoted(key)): \(quoted)\n}\n"
        }
        let ns = text as NSString
        if let match = regex.firstMatch(in: text, options: [], range: scope) {
            return ns.replacingCharacters(in: match.range(at: 1), with: quoted)
        }
        let insertAt = scope.location + 1
        let rest = ns.substring(from: insertAt)
        let isEmptyObject = rest.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("}")
        let entry = "\n    \(jsonQuoted(key)): \(quoted)" + (isEmptyObject ? "\n" : ",")
        return ns.replacingCharacters(in: NSRange(location: insertAt, length: 0), with: entry)
    }
}

// MARK: - Config formats

enum TransmissionSettings {
    static let kebabKey = "bind-address-ipv4"
    static let snakeKey = "bind_address_ipv4"

    static func bindAddress(in text: String) -> String? {
        JSONConfigText.stringValue(snakeKey, in: text)
            ?? JSONConfigText.stringValue(kebabKey, in: text)
    }

    /// Keeps whichever spelling the file already uses (4.1 writes snake_case).
    static func applyBindAddress(_ address: String, to text: String) -> String {
        let key: String
        if text.contains("\"\(snakeKey)\"") {
            key = snakeKey
        } else if text.contains("\"\(kebabKey)\"") {
            key = kebabKey
        } else if text.range(of: "\"[a-z]+_[a-z_]+\"\\s*:", options: .regularExpression) != nil,
                  text.range(of: "\"[a-z]+-[a-z-]+\"\\s*:", options: .regularExpression) == nil {
            key = snakeKey
        } else {
            key = kebabKey
        }
        return JSONConfigText.setting(key, to: address, in: text)
    }
}

enum DelugeCoreConf {
    static let listenKey = "listen_interface"
    static let outgoingKey = "outgoing_interface"

    static func binding(in text: String) -> (outgoing: String?, listen: String?) {
        (JSONConfigText.stringValue(outgoingKey, in: text),
         JSONConfigText.stringValue(listenKey, in: text))
    }

    static func applyBinding(interface: String, address: String, to text: String) -> String {
        var source = text
        if JSONConfigText.topLevelObjectOpenings(in: source).isEmpty {
            source = "{\n    \"file\": 1,\n    \"format\": 1\n}{\n}\n"
        }
        let withOutgoing = JSONConfigText.setting(outgoingKey, to: interface, in: source)
        return JSONConfigText.setting(listenKey, to: address, in: withOutgoing)
    }
}
