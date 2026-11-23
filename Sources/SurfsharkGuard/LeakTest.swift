import Foundation
import SwiftUI

/// What the on-demand leak test concluded.
enum LeakVerdict: Equatable {
    /// Tunnel and normal connection show different public IPs.
    case sealed
    /// Tunnel answers, the normal connection is blocked (VPN kill switch).
    case sealedBlocked
    /// The tunnel shows the same public IP as the normal connection.
    case leak
    /// No answer through the tunnel at all.
    case tunnelUnreachable
    /// No VPN tunnel to test.
    case noTunnel

    var symbolName: String {
        switch self {
        case .sealed, .sealedBlocked: return "checkmark.shield.fill"
        case .leak: return "exclamationmark.shield.fill"
        case .tunnelUnreachable: return "questionmark.circle.fill"
        case .noTunnel: return "shield.slash"
        }
    }

    var color: Color {
        switch self {
        case .sealed, .sealedBlocked: return .green
        case .leak: return .red
        case .tunnelUnreachable, .noTunnel: return .orange
        }
    }

    var headline: String {
        switch self {
        case .sealed: return "No leak — the tunnel hides your real IP"
        case .sealedBlocked: return "No leak — traffic outside the tunnel is blocked"
        case .leak: return "Leak — the tunnel shows your real IP"
        case .tunnelUnreachable: return "No answer through the tunnel"
        case .noTunnel: return "No VPN tunnel to test"
        }
    }
}

struct LeakTestResult: Equatable {
    var tunnelInterface: String?
    var tunnelIP: String?
    var physicalInterface: String?
    var physicalIP: String?
    var verdict: LeakVerdict
    var checkedAt: Date
}

/// Asks a public "what is my IP" service once through the VPN tunnel and
/// once through the normal (Wi‑Fi/Ethernet) interface, then compares.
/// Runs only when the user presses the button — never on a timer.
enum LeakTest {
    /// Plain-text IPv4 echo services, tried in order.
    static let services = [
        "https://api.ipify.org",
        "https://ipv4.icanhazip.com",
    ]

    static func verdict(tunnelInterface: String?,
                        tunnelIP: String?,
                        physicalIP: String?) -> LeakVerdict {
        guard tunnelInterface != nil else { return .noTunnel }
        guard let tunnelIP else { return .tunnelUnreachable }
        guard let physicalIP else { return .sealedBlocked }
        return tunnelIP == physicalIP ? .leak : .sealed
    }

    /// The non-VPN interface that carries a default route (`en0` etc.).
    /// Falls back to the first `en*` interface with an IPv4 address.
    static func physicalInterface(netstatText: String,
                                  ifconfigText: String) -> String? {
        for line in netstatText.split(separator: "\n") {
            guard line.first != " " else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4, parts[0] == "default" else { continue }
            let iface = String(parts[3])
            if isPhysicalInterface(iface) { return iface }
        }
        let ifaces = IfconfigParser.parse(ifconfigText)
        return ifaces
            .filter { $0.key.hasPrefix("en") && $0.value.ipv4 != nil && $0.value.up }
            .keys.sorted().first
    }

    static func isPhysicalInterface(_ name: String) -> Bool {
        guard !isVPNInterface(name) else { return false }
        for prefix in ["lo", "gif", "stf", "bridge", "awdl", "llw", "anpi", "ap"]
        where name.hasPrefix(prefix) {
            return false
        }
        return !name.isEmpty
    }

    /// Accepts only a bare dotted IPv4 answer (rejects captive-portal HTML etc.).
    static func parsePublicIPv4(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let value = Int(part), value <= 255 else { return nil }
        }
        return trimmed
    }

    /// Public IPv4 as seen when leaving through `iface`, or nil.
    /// `curl --interface` binds the socket to that interface, so the request
    /// cannot silently fall back to another route.
    static func publicIP(via iface: String) -> String? {
        for service in services {
            let out = Shell.run("/usr/bin/curl", [
                "-4", "-s", "-f",
                "--interface", iface,
                "--connect-timeout", "3",
                "--max-time", "4",
                service,
            ])
            if let ip = parsePublicIPv4(out) { return ip }
        }
        return nil
    }

    private static func publicIPDetached(_ iface: String?) async -> String? {
        guard let iface else { return nil }
        return await Task.detached(priority: .userInitiated) {
            LeakTest.publicIP(via: iface)
        }.value
    }

    /// Tunnel and normal interface are queried in parallel.
    static func run(tunnelInterface: String?) async -> LeakTestResult {
        let physical = await Task.detached(priority: .userInitiated) {
            LeakTest.physicalInterface(
                netstatText: Shell.run("/usr/sbin/netstat", ["-rn", "-f", "inet"]),
                ifconfigText: Shell.run("/sbin/ifconfig", ["-a"])
            )
        }.value
        async let tunnelLookup = publicIPDetached(tunnelInterface)
        async let physicalLookup = publicIPDetached(tunnelInterface == nil ? nil : physical)
        let (tunnelIP, physicalIP) = await (tunnelLookup, physicalLookup)
        return LeakTestResult(
            tunnelInterface: tunnelInterface,
            tunnelIP: tunnelIP,
            physicalInterface: physical,
            physicalIP: physicalIP,
            verdict: verdict(tunnelInterface: tunnelInterface,
                             tunnelIP: tunnelIP,
                             physicalIP: physicalIP),
            checkedAt: Date()
        )
    }
}

@MainActor
final class LeakTestModel: ObservableObject {
    static let shared = LeakTestModel()

    @Published var result: LeakTestResult?
    @Published var running = false

    func run(state: GuardState) async {
        guard !running else { return }
        running = true
        defer { running = false }
        // Use a fresh tunnel reading so the test hits the current utun.
        await state.checkNow(notifyAbout: false)
        let iface = state.snapshot?.tunnel?.iface
        result = await LeakTest.run(tunnelInterface: iface)
    }
}

struct LeakTestCard: View {
    @EnvironmentObject private var state: GuardState
    @ObservedObject private var model = LeakTestModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: model.result?.verdict.symbolName ?? "network.badge.shield.half.filled")
                    .foregroundStyle(model.result?.verdict.color ?? Color.secondary)
                    .frame(width: 18)
                Text(headline)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                Spacer(minLength: 4)
                Button {
                    Task { await model.run(state: state) }
                } label: {
                    if model.running {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.small)
                            Text("Testing…")
                        }
                    } else {
                        Text(model.result == nil ? "Run leak test" : "Test again")
                    }
                }
                .controlSize(.small)
                .disabled(model.running)
                .help("Asks api.ipify.org (fallback icanhazip.com) for your public IP through the tunnel and through Wi‑Fi/Ethernet, then compares.")
            }
            if let r = model.result, r.verdict != .noTunnel {
                VStack(alignment: .leading, spacing: 2) {
                    ipRow("Tunnel", r.tunnelInterface, r.tunnelIP, fallback: "no answer")
                    ipRow("Normal", r.physicalInterface, r.physicalIP,
                          fallback: r.physicalInterface == nil ? "not found" : "blocked")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 26)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((model.result?.verdict.color ?? Color.primary).opacity(0.06))
        )
        .animation(.easeInOut(duration: 0.2), value: model.result)
    }

    private var headline: String {
        guard let r = model.result else { return "Leak test" }
        let time = r.checkedAt.formatted(date: .omitted, time: .shortened)
        return "\(r.verdict.headline) · \(time)"
    }

    private func ipRow(_ label: String, _ iface: String?, _ ip: String?,
                       fallback: String) -> some View {
        HStack(spacing: 4) {
            Text(label).frame(width: 50, alignment: .leading)
            Text(iface ?? "–").font(.caption.monospaced())
            Text("·")
            Text(ip ?? fallback).font(.caption.monospaced())
                .textSelection(.enabled)
        }
    }
}
