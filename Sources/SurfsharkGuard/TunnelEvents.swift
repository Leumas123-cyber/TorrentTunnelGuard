import Foundation

/// What happened to the VPN tunnel between two checks.
enum TunnelEvent: Equatable {
    case connected(String)
    case switched(from: String, to: String)
    case dropped(String)

    /// `previous` / `current` are the tunnel interfaces (e.g. "utun3") of two
    /// consecutive checks; nil means no tunnel at that check.
    static func between(previous: String?, current: String?) -> TunnelEvent? {
        switch (previous, current) {
        case (nil, nil):
            return nil
        case let (nil, now?):
            return .connected(now)
        case let (old?, nil):
            return .dropped(old)
        case let (old?, now?):
            return old == now ? nil : .switched(from: old, to: now)
        }
    }
}

struct NoticeText: Equatable {
    let title: String
    let body: String
}

enum TunnelNotice {
    /// The informational notification for a tunnel change or a live rebind.
    ///
    /// Returns nil when nothing should be posted here: a drop or a still-wrong
    /// binding is already covered by the problem notification, so posting here
    /// too would double up.
    static func text(event: TunnelEvent?, tunnel: String?, bindingOK: Bool,
                     rebound: Bool, clientName: String = "qBittorrent") -> NoticeText? {
        guard bindingOK || rebound else { return nil }
        switch event {
        case .connected(let iface):
            return NoticeText(
                title: "Surfshark Guard — VPN connected",
                body: rebound
                    ? "Tunnel \(iface) is up. \(clientName) was rebound to it."
                    : "Tunnel \(iface) is up and \(clientName) is bound to it.")
        case let .switched(old, new):
            return NoticeText(
                title: "Surfshark Guard — tunnel changed",
                body: rebound
                    ? "\(old) → \(new). \(clientName) was rebound to the new tunnel."
                    : "\(old) → \(new). \(clientName) is on the new tunnel.")
        case .dropped:
            return nil
        case nil:
            guard rebound, let tunnel else { return nil }
            return NoticeText(
                title: "Surfshark Guard — \(clientName) rebound",
                body: "\(clientName) is bound to \(tunnel) again.")
        }
    }

    /// Body of the problem notification when the tunnel is gone.
    static func noTunnelBody(droppedFrom: String?) -> String {
        if let droppedFrom {
            return "VPN tunnel \(droppedFrom) went down — torrents should stay paused."
        }
        return "No VPN tunnel — torrents should stay paused."
    }
}
