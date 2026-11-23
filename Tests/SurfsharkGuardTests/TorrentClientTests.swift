import XCTest
@testable import SurfsharkGuard

final class TorrentClientTests: XCTestCase {
    private var ifaces: [String: IfInfo] { IfconfigParser.parse(fixtureIfconfig) }

    func testClientDefaultsKeepQBittorrentKeys() {
        XCTAssertEqual(TorrentClient.qbittorrent.defaultsKey("webuiURL"), "webuiURL")
        XCTAssertEqual(TorrentClient.transmission.defaultsKey("webuiURL"), "transmission.webuiURL")
        XCTAssertEqual(TorrentClient.qbittorrent.keychainAccount, KeychainStore.account)
        XCTAssertEqual(TorrentClient.deluge.keychainAccount, "deluge")
    }

    func testCredentialsPerClient() {
        XCTAssertFalse(TorrentClient.qbittorrent.credentialsReady(user: "", password: "x"))
        XCTAssertTrue(TorrentClient.transmission.credentialsReady(user: "", password: ""))
        XCTAssertFalse(TorrentClient.deluge.credentialsReady(user: "", password: ""))
        XCTAssertTrue(TorrentClient.deluge.credentialsReady(user: "", password: "deluge"))
    }

    func testProcessAndAppMatching() {
        XCTAssertTrue(TorrentClient.transmission.matchesProcessLine("501 /Applications/Transmission.app/Contents/MacOS/Transmission"))
        XCTAssertTrue(TorrentClient.transmission.matchesProcessLine("502 transmission-daemon -f"))
        XCTAssertFalse(TorrentClient.transmission.matchesProcessLine("503 qbittorrent"))
        XCTAssertTrue(TorrentClient.deluge.matchesProcessLine("504 /usr/local/bin/deluged"))
        XCTAssertFalse(TorrentClient.deluge.matchesProcessLine("505 /usr/local/bin/deluge-web"))
        XCTAssertFalse(TorrentClient.qbittorrent.matchesProcessLine("506 SurfsharkGuard qbittorrent"))

        XCTAssertTrue(TorrentClient.transmission.matchesApp(bundleID: "org.m0k.transmission", name: "Transmission"))
        XCTAssertFalse(TorrentClient.transmission.matchesApp(bundleID: "org.qbittorrent.qBittorrent", name: "qBittorrent"))
        XCTAssertTrue(TorrentClient.qbittorrent.matchesApp(bundleID: "org.qbittorrent.qBittorrent", name: nil))
    }

    func testTransmissionBindingResolution() {
        let bound = ClientBinding.transmission(bindAddress: "10.14.0.2", ifaces: ifaces)
        XCTAssertEqual(bound.iface, "utun9")
        XCTAssertEqual(bound.addr, "10.14.0.2")

        let stale = ClientBinding.transmission(bindAddress: "10.99.0.2", ifaces: ifaces)
        XCTAssertNil(stale.iface)

        let open = ClientBinding.transmission(bindAddress: "0.0.0.0", ifaces: ifaces)
        XCTAssertNil(open.iface)
        XCTAssertNil(ClientBinding.transmission(bindAddress: nil, ifaces: ifaces).iface)

        let tunnel = TunnelInfo(iface: "utun9", ip: "10.14.0.2", mtu: nil, wireGuard: true,
                                vpnRunning: true, vpnName: nil, why: [], otherCandidates: [])
        XCTAssertTrue(bindingMatchesTunnel(interface: bound.iface, address: bound.addr, tunnel: tunnel))
        XCTAssertFalse(bindingMatchesTunnel(interface: open.iface, address: open.addr, tunnel: tunnel))
    }

    func testDelugeBindingResolution() {
        let named = ClientBinding.deluge(outgoing: "utun9", listen: "10.14.0.2", ifaces: ifaces)
        XCTAssertEqual(named.iface, "utun9")
        XCTAssertEqual(named.addr, "10.14.0.2")

        let byIP = ClientBinding.deluge(outgoing: "10.14.0.2", listen: "utun9", ifaces: ifaces)
        XCTAssertEqual(byIP.iface, "utun9")
        XCTAssertEqual(byIP.addr, "10.14.0.2")

        let listenAll = ClientBinding.deluge(outgoing: "utun9", listen: "", ifaces: ifaces)
        XCTAssertEqual(listenAll.addr, "0.0.0.0")
        let tunnel = TunnelInfo(iface: "utun9", ip: "10.14.0.2", mtu: nil, wireGuard: true,
                                vpnRunning: true, vpnName: nil, why: [], otherCandidates: [])
        XCTAssertFalse(bindingMatchesTunnel(interface: listenAll.iface, address: listenAll.addr,
                                            tunnel: tunnel))

        XCTAssertNil(ClientBinding.deluge(outgoing: "", listen: "", ifaces: ifaces).iface)
    }

    func testTransmissionSettingsEditKeepsOtherValues() {
        let original = """
        {
            "bind-address-ipv4": "0.0.0.0",
            "ratio-limit": 2.0,
            "rpc-whitelist": "127.0.0.1,::1"
        }
        """
        let edited = TransmissionSettings.applyBindAddress("10.14.0.2", to: original)
        XCTAssertEqual(TransmissionSettings.bindAddress(in: edited), "10.14.0.2")
        XCTAssertTrue(edited.contains("\"ratio-limit\": 2.0"))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(edited.utf8)))

        let snake = TransmissionSettings.applyBindAddress("10.14.0.2",
                                                          to: "{\n    \"rpc_port\": 9091\n}\n")
        XCTAssertTrue(snake.contains("\"bind_address_ipv4\": \"10.14.0.2\""))
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(snake.utf8)))

        let fresh = TransmissionSettings.applyBindAddress("10.14.0.2", to: "")
        XCTAssertEqual(TransmissionSettings.bindAddress(in: fresh), "10.14.0.2")
    }

    func testDelugeCoreConfEdit() throws {
        let original = """
        {
            "file": 1,
            "format": 1
        }{
            "listen_interface": "",
            "max_upload_speed": -1.0,
            "move_completed_path": "/Users/me/Downloads"
        }
        """
        let edited = DelugeCoreConf.applyBinding(interface: "utun9", address: "10.14.0.2",
                                                 to: original)
        let binding = DelugeCoreConf.binding(in: edited)
        XCTAssertEqual(binding.outgoing, "utun9")
        XCTAssertEqual(binding.listen, "10.14.0.2")
        XCTAssertTrue(edited.contains("\"max_upload_speed\": -1.0"))
        XCTAssertTrue(edited.hasPrefix("{\n    \"file\": 1,\n    \"format\": 1\n}{"))

        let openings = JSONConfigText.topLevelObjectOpenings(in: edited)
        XCTAssertEqual(openings.count, 2)
        let second = String(edited.utf16.dropFirst(openings[1]))!
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(second.utf8)))

        let fresh = DelugeCoreConf.applyBinding(interface: "utun9", address: "10.14.0.2", to: "")
        XCTAssertEqual(DelugeCoreConf.binding(in: fresh).outgoing, "utun9")
        XCTAssertEqual(DelugeCoreConf.binding(in: fresh).listen, "10.14.0.2")
    }

    func testJSONTextHandlesBracesInStrings() {
        let text = "{\"a\": \"{not an object}\", \"listen_interface\": null}"
        XCTAssertEqual(JSONConfigText.topLevelObjectOpenings(in: text), [0])
        XCTAssertNil(JSONConfigText.stringValue("listen_interface", in: text))
        let edited = JSONConfigText.setting("listen_interface", to: "10.0.0.1", in: text)
        XCTAssertEqual(JSONConfigText.stringValue("listen_interface", in: edited), "10.0.0.1")
        XCTAssertEqual(JSONConfigText.stringValue("a", in: edited), "{not an object}")
    }

    func testTransmissionRPCEndpoint() {
        XCTAssertEqual(
            TransmissionRPC.rpcEndpoint(for: URL(string: "http://127.0.0.1:9091")!).absoluteString,
            "http://127.0.0.1:9091/transmission/rpc")
        XCTAssertEqual(
            TransmissionRPC.rpcEndpoint(for: URL(string: "http://127.0.0.1:9091/transmission/rpc")!).absoluteString,
            "http://127.0.0.1:9091/transmission/rpc")
        XCTAssertEqual(
            DelugeWebUI.jsonEndpoint(for: URL(string: "http://127.0.0.1:8112")!).absoluteString,
            "http://127.0.0.1:8112/json")
    }

    func testTransmissionRPCHandlesSessionIdHandshake() async {
        let session = stubSession()
        RemoteStub.handler = { request in
            if request.value(forHTTPHeaderField: "X-Transmission-Session-Id") != "abc" {
                return (409, ["X-Transmission-Session-Id": "abc"], Data())
            }
            return (200, [:], Data(#"{"result":"success","arguments":{}}"#.utf8))
        }
        let rpc = TransmissionRPC(baseURL: URL(string: "http://127.0.0.1:9091")!,
                                  user: "", password: "", session: session)
        let loggedIn = await rpc.login()
        let stopped = await rpc.stopAllTorrents()
        XCTAssertTrue(loggedIn)
        XCTAssertTrue(stopped)

        RemoteStub.handler = { _ in (401, [:], Data()) }
        let rejected = TransmissionRPC(baseURL: URL(string: "http://127.0.0.1:9091")!,
                                       user: "u", password: "p", session: session)
        let rejectedLogin = await rejected.login()
        XCTAssertFalse(rejectedLogin)
    }

    func testDelugeWebUILoginAndRebind() async {
        let session = stubSession()
        RemoteStub.handler = { request in
            let body = RemoteStub.body(of: request)
            let method = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["method"]
                as? String ?? ""
            let result: String
            switch method {
            case "auth.login": result = "true"
            case "web.connected": result = "true"
            case "core.get_config_values":
                result = #"{"outgoing_interface": "en0", "listen_interface": ""}"#
            case "core.set_config", "core.pause_torrents": result = "null"
            default:
                return (200, [:], Data(#"{"result": null, "error": {"message": "unknown"}, "id": 1}"#.utf8))
            }
            return (200, [:], Data(#"{"result": \#(result), "error": null, "id": 1}"#.utf8))
        }
        let ui = DelugeWebUI(baseURL: URL(string: "http://127.0.0.1:8112")!,
                             password: "deluge", session: session)
        let loggedIn = await ui.login()
        let binding = await ui.currentBinding()
        let set = await ui.setBinding(interface: "utun9", address: "10.14.0.2")
        let paused = await ui.pauseAllTorrents()
        XCTAssertTrue(loggedIn)
        XCTAssertEqual(binding?.outgoing, "en0")
        XCTAssertEqual(binding?.listen, "")
        XCTAssertTrue(set)
        XCTAssertTrue(paused)

        RemoteStub.handler = { _ in
            (200, [:], Data(#"{"result": false, "error": null, "id": 1}"#.utf8))
        }
        let wrong = DelugeWebUI(baseURL: URL(string: "http://127.0.0.1:8112")!,
                                password: "nope", session: session)
        let wrongLogin = await wrong.login()
        XCTAssertFalse(wrongLogin)
    }

    func testRemotesRefuseNonLocalURLs() async {
        let session = stubSession()
        RemoteStub.handler = { _ in (200, [:], Data(#"{"result":"success"}"#.utf8)) }
        let rpc = TransmissionRPC(baseURL: URL(string: "http://example.com:9091")!,
                                  user: "", password: "", session: session)
        let ok = await rpc.login()
        XCTAssertFalse(ok)
    }

    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteStub.self]
        return URLSession(configuration: config)
    }
}

private final class RemoteStub: URLProtocol {
    static var handler: ((URLRequest) -> (Int, [String: String], Data))?

    static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
