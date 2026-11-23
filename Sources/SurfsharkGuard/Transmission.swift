import Foundation

/// Transmission config. Transmission.app keeps its bind address in its own
/// preferences (`org.m0k.transmission`, key `BindAddressIPv4`);
/// transmission-daemon reads `bind-address-ipv4` from settings.json.
/// Both are only read at start-up, so a fix needs Transmission to be quit.
enum TransmissionConfig {
    static let appDomain = "org.m0k.transmission"
    static let appKey = "BindAddressIPv4"
    static let fm = FileManager.default

    static var appPlistPath: String {
        "\(NSHomeDirectory())/Library/Preferences/\(appDomain).plist"
    }

    static func daemonSettingsCandidates() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/Library/Application Support/transmission-daemon/settings.json",
            "\(home)/.config/transmission-daemon/settings.json",
        ]
    }

    static func existingDaemonSettings() -> [String] {
        daemonSettingsCandidates().filter { fm.fileExists(atPath: $0) }
    }

    static var appInstalledOrConfigured: Bool {
        fm.fileExists(atPath: appPlistPath)
            || fm.fileExists(atPath: "/Applications/Transmission.app")
    }

    static func readAppBindAddress() -> String? {
        _ = CFPreferencesAppSynchronize(appDomain as CFString)
        return CFPreferencesCopyAppValue(appKey as CFString, appDomain as CFString) as? String
    }

    /// Which config is live: a running daemon's settings.json wins, then the
    /// Mac app, then any daemon settings file.
    static func read(daemonRunning: Bool) -> (address: String?, source: String?, path: String?) {
        let daemonFiles = existingDaemonSettings()
        if daemonRunning || !appInstalledOrConfigured, let path = daemonFiles.first,
           let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return (TransmissionSettings.bindAddress(in: text), "settings.json", path)
        }
        if appInstalledOrConfigured {
            return (readAppBindAddress(), "app prefs", appPlistPath)
        }
        return (nil, nil, nil)
    }

    static var writeTargetDescription: String {
        existingDaemonSettings().first ?? appPlistPath
    }

    /// Writes the tunnel IP to every Transmission config found. With none
    /// found it sets the Mac app preference.
    @discardableResult
    static func writeBindAddress(_ address: String) throws -> [String] {
        var written: [String] = []
        for path in existingDaemonSettings() {
            let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let backup = path + ".bak-" + timestamp()
            if !old.isEmpty {
                try old.write(toFile: backup, atomically: true, encoding: .utf8)
            }
            let new = TransmissionSettings.applyBindAddress(address, to: old)
            try new.write(toFile: path, atomically: true, encoding: .utf8)
            written.append("\((path as NSString).lastPathComponent): bind address \(address)")
        }
        if appInstalledOrConfigured || written.isEmpty {
            CFPreferencesSetAppValue(appKey as CFString, address as CFString,
                                     appDomain as CFString)
            guard CFPreferencesAppSynchronize(appDomain as CFString) else {
                throw CocoaError(.fileWriteUnknown)
            }
            written.append("Transmission.app: \(appKey)=\(address)")
        }
        return written
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }
}

/// Minimal Transmission RPC client: login check and stop-all.
/// Uses the classic protocol, which Transmission 2.x through 4.x accept.
final class TransmissionRPC: @unchecked Sendable {
    let rpcURL: URL
    let user: String
    let password: String
    private let session: URLSession
    private var sessionID: String?

    init(baseURL: URL, user: String, password: String, session: URLSession? = nil) {
        self.rpcURL = Self.rpcEndpoint(for: baseURL)
        self.user = user
        self.password = password
        self.session = session ?? Self.makeSession()
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.timeoutIntervalForResource = 4
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }

    /// `http://127.0.0.1:9091` becomes `.../transmission/rpc`; a full path is kept.
    static func rpcEndpoint(for baseURL: URL) -> URL {
        let path = baseURL.path
        if path.isEmpty || path == "/" {
            return QBWebUI.endpoint("/transmission/rpc", on: baseURL)
        }
        return baseURL
    }

    private func request(_ method: String, arguments: [String: Any] = [:])
        async throws -> [String: Any]? {
        guard WebUIURLValidator.isAllowed(rpcURL) else { throw URLError(.unsupportedURL) }
        let payload: [String: Any] = ["method": method, "arguments": arguments, "tag": 1]
        let body = try JSONSerialization.data(withJSONObject: payload)

        for _ in 0..<2 {
            var req = URLRequest(url: rpcURL)
            req.httpMethod = "POST"
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let sessionID {
                req.setValue(sessionID, forHTTPHeaderField: "X-Transmission-Session-Id")
            }
            if !user.isEmpty || !password.isEmpty {
                let token = Data("\(user):\(password)".utf8).base64EncodedString()
                req.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 409,
               let id = http.value(forHTTPHeaderField: "X-Transmission-Session-Id") {
                sessionID = id
                continue
            }
            guard (200...299).contains(http.statusCode) else { return nil }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        return nil
    }

    private func succeeded(_ method: String, arguments: [String: Any] = [:]) async -> Bool {
        guard let reply = try? await request(method, arguments: arguments) else { return false }
        return reply["result"] as? String == "success"
    }

    static func probe(baseURL: URL) async -> WebUIReachability {
        let url = rpcEndpoint(for: baseURL)
        guard WebUIURLValidator.isAllowed(url) else { return .offline }
        var req = URLRequest(url: url)
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

    /// Works with and without RPC authentication.
    func login() async -> Bool {
        await succeeded("session-get", arguments: ["fields": ["version"]])
    }

    /// No ids means every torrent.
    func stopAllTorrents() async -> Bool {
        await succeeded("torrent-stop")
    }
}
