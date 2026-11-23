import Foundation

/// One remote-control connection to whichever client is selected.
enum TorrentRemote {
    case qbittorrent(QBWebUI)
    case transmission(TransmissionRPC)
    case deluge(DelugeWebUI)

    init(client: TorrentClient, baseURL: URL, user: String, password: String) {
        switch client {
        case .qbittorrent:
            self = .qbittorrent(QBWebUI(baseURL: baseURL, user: user, password: password))
        case .transmission:
            self = .transmission(TransmissionRPC(baseURL: baseURL, user: user, password: password))
        case .deluge:
            self = .deluge(DelugeWebUI(baseURL: baseURL, password: password))
        }
    }

    static func probe(client: TorrentClient, baseURL: URL) async -> WebUIReachability {
        switch client {
        case .qbittorrent: return await QBWebUI.probe(baseURL: baseURL)
        case .transmission: return await TransmissionRPC.probe(baseURL: baseURL)
        case .deluge: return await DelugeWebUI.probe(baseURL: baseURL)
        }
    }

    func login() async -> Bool {
        switch self {
        case .qbittorrent(let ui): return await ui.login()
        case .transmission(let rpc): return await rpc.login()
        case .deluge(let ui): return await ui.login()
        }
    }

    /// Live binding, already resolved to (interface, address).
    /// Transmission's RPC cannot report it, so the config file stays the source.
    func currentBinding(ifaces: [String: IfInfo]) async -> (iface: String?, addr: String?)? {
        switch self {
        case .qbittorrent(let ui):
            return await ui.currentBinding()
        case .transmission:
            return nil
        case .deluge(let ui):
            guard let raw = await ui.currentBinding() else { return nil }
            return ClientBinding.deluge(outgoing: raw.outgoing, listen: raw.listen,
                                        ifaces: ifaces)
        }
    }

    /// Rebinds the running client. `false` when the client cannot do it live.
    func setBinding(interface: String, address: String?, keepAddress: String?) async -> Bool {
        switch self {
        case .qbittorrent(let ui):
            return await ui.setInterface(interface, address: keepAddress)
        case .transmission:
            return false
        case .deluge(let ui):
            guard let address else { return false }
            return await ui.setBinding(interface: interface, address: address)
        }
    }

    func pauseAllTorrents() async -> Bool {
        switch self {
        case .qbittorrent(let ui): return await ui.pauseAllTorrents()
        case .transmission(let rpc): return await rpc.stopAllTorrents()
        case .deluge(let ui): return await ui.pauseAllTorrents()
        }
    }
}

/// Binding as stored on disk for the selected client.
struct ClientConfigState {
    var iface: String?
    var addr: String?
    var source: String?
    var configPath: String?
    var writeTarget: String

    static func read(client: TorrentClient, ifaces: [String: IfInfo],
                     processText: String) -> ClientConfigState {
        switch client {
        case .qbittorrent:
            let (existing, target) = QBittorrent.findConfig()
            var state = ClientConfigState(configPath: existing, writeTarget: target)
            if let path = existing,
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                (state.iface, state.addr) = IniEditor.binding(in: text)
                if state.iface != nil { state.source = "ini" }
            }
            return state
        case .transmission:
            let daemonRunning = processText.lowercased().contains("transmission-daemon")
            let read = TransmissionConfig.read(daemonRunning: daemonRunning)
            let resolved = ClientBinding.transmission(bindAddress: read.address, ifaces: ifaces)
            return ClientConfigState(
                iface: resolved.iface, addr: resolved.addr, source: read.source,
                configPath: read.path,
                writeTarget: read.path ?? TransmissionConfig.writeTargetDescription)
        case .deluge:
            let (existing, target) = DelugeConfig.findConfig()
            let read = DelugeConfig.read()
            let resolved = ClientBinding.deluge(outgoing: read.outgoing, listen: read.listen,
                                                ifaces: ifaces)
            return ClientConfigState(
                iface: resolved.iface, addr: resolved.addr,
                source: existing == nil ? nil : "core.conf",
                configPath: existing, writeTarget: target)
        }
    }
}
