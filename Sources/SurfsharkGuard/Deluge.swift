import Foundation

/// Deluge's core.conf. deluged and the Deluge app both read it at start-up
/// and write it back on exit, so the file is only edited while Deluge is quit.
enum DelugeConfig {
    static let fm = FileManager.default

    static func candidates() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.config/deluge/core.conf",
            "\(home)/Library/Application Support/deluge/core.conf",
        ]
    }

    /// Newest existing core.conf, plus where a fix would be written.
    static func findConfig() -> (existing: String?, writeTarget: String) {
        let found = candidates().compactMap { path -> (Date, String)? in
            guard fm.fileExists(atPath: path) else { return nil }
            let date = (try? fm.attributesOfItem(atPath: path))?[.modificationDate]
                as? Date ?? .distantPast
            return (date, path)
        }
        if let newest = found.sorted(by: { $0.0 > $1.0 }).first {
            return (newest.1, newest.1)
        }
        return (nil, candidates()[0])
    }

    static func read() -> (outgoing: String?, listen: String?, path: String?) {
        guard let path = findConfig().existing,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return (nil, nil, nil) }
        let binding = DelugeCoreConf.binding(in: text)
        return (binding.outgoing, binding.listen, path)
    }

    @discardableResult
    static func writeBinding(interface: String, address: String) throws -> [String] {
        let target = findConfig().writeTarget
        let old = (try? String(contentsOfFile: target, encoding: .utf8)) ?? ""
        let backup = target + ".bak-" + timestamp()
        if !old.isEmpty {
            try old.write(toFile: backup, atomically: true, encoding: .utf8)
        } else {
            try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent,
                                   withIntermediateDirectories: true)
        }
        let new = DelugeCoreConf.applyBinding(interface: interface, address: address, to: old)
        try new.write(toFile: target, atomically: true, encoding: .utf8)
        var lines = ["outgoing_interface=\(interface)", "listen_interface=\(address)"]
        if !old.isEmpty { lines.append("Backup: \((backup as NSString).lastPathComponent)") }
        return lines
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// Minimal Deluge Web UI (JSON-RPC at /json) client. The Web UI only has a
/// password; it must be connected to a daemon for the core.* calls to work.
final class DelugeWebUI: @unchecked Sendable {
    let jsonURL: URL
    let password: String
    private let session: URLSession
    private var nextID = 1

    init(baseURL: URL, password: String, session: URLSession? = nil) {
        self.jsonURL = Self.jsonEndpoint(for: baseURL)
        self.password = password
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    static func jsonEndpoint(for baseURL: URL) -> URL {
        if baseURL.path.hasSuffix("/json") { return baseURL }
        return QBWebUI.endpoint("json", on: baseURL)
    }

    struct CallError: Error {}

    /// Returns the `result` value, or throws when Deluge reports an error.
    private func call(_ method: String, _ params: [Any] = []) async throws -> Any? {
        guard WebUIURLValidator.isAllowed(jsonURL) else { throw URLError(.unsupportedURL) }
        let id = nextID
        nextID += 1
        let payload: [String: Any] = ["method": method, "params": params, "id": id]
        var req = URLRequest(url: jsonURL)
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw CallError() }
        if let error = reply["error"], !(error is NSNull) { throw CallError() }
        let result = reply["result"]
        return result is NSNull ? nil : result
    }

    static func probe(baseURL: URL) async -> WebUIReachability {
        guard WebUIURLValidator.isAllowed(baseURL) else { return .offline }
        var req = URLRequest(url: baseURL)
        req.httpMethod = "GET"
        req.timeoutInterval = 1.5
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 1.5
        config.timeoutIntervalForResource = 2
        config.waitsForConnectivity = false
        do {
            let (_, response) = try await URLSession(configuration: config).data(for: req)
            return response is HTTPURLResponse ? .online : .offline
        } catch {
            return .offline
        }
    }

    /// Logs in and makes sure the Web UI is connected to a daemon.
    func login() async -> Bool {
        guard !password.isEmpty,
              (try? await call("auth.login", [password])) as? Bool == true
        else { return false }
        if (try? await call("web.connected")) as? Bool == true { return true }
        guard let hosts = (try? await call("web.get_hosts")) as? [[Any]],
              let hostID = hosts.first?.first as? String
        else { return false }
        _ = try? await call("web.connect", [hostID])
        return (try? await call("web.connected")) as? Bool == true
    }

    /// Raw `outgoing_interface` / `listen_interface` from the running daemon.
    func currentBinding() async -> (outgoing: String?, listen: String?)? {
        guard let values = (try? await call(
            "core.get_config_values",
            [[DelugeCoreConf.outgoingKey, DelugeCoreConf.listenKey]]
        )) as? [String: Any] else { return nil }
        return (values[DelugeCoreConf.outgoingKey] as? String,
                values[DelugeCoreConf.listenKey] as? String)
    }

    func setBinding(interface: String, address: String) async -> Bool {
        let config: [String: Any] = [
            DelugeCoreConf.outgoingKey: interface,
            DelugeCoreConf.listenKey: address,
        ]
        return await succeeds("core.set_config", [config])
    }

    private func succeeds(_ method: String, _ params: [Any] = []) async -> Bool {
        do {
            _ = try await call(method, params)
            return true
        } catch {
            return false
        }
    }

    /// Deluge 2 pauses everything with no ids; older builds need the ids,
    /// and 1.3 has pause_all_torrents.
    func pauseAllTorrents() async -> Bool {
        if await succeeds("core.pause_torrents") { return true }
        if let status = (try? await call("core.get_torrents_status",
                                         [[String: Any](), ["state"]])) as? [String: Any] {
            if status.isEmpty { return true }
            if await succeeds("core.pause_torrents", [Array(status.keys)]) { return true }
        }
        if await succeeds("core.pause_all_torrents") { return true }
        return await succeeds("core.pause_session")
    }
}
