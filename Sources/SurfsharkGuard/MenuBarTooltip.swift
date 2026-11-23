import Foundation

enum MenuBarTooltip {
    static let unchecked = "Surfshark Guard — not checked yet"

    static func text(tunnel: String?, qbInterface: String?,
                     clientName: String = TorrentClient.qbittorrent.shortName) -> String {
        guard let tunnel else { return "No VPN tunnel" }
        if qbInterface == tunnel { return "\(tunnel) · sealed" }
        return "\(tunnel) · leak risk — \(clientName) on \(qbInterface ?? "none")"
    }
}
