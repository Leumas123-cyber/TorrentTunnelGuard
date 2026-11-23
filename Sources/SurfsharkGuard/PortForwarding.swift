import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// NAT-PMP (RFC 6886) port mapping, as used by Proton VPN port forwarding.
/// Only the wire format lives in `NATPMP`; the socket code is in `NATPMPClient`.
enum NATPMP {
    enum Proto: UInt8 {
        case udp = 1
        case tcp = 2
    }

    struct Mapping: Equatable {
        var proto: Proto
        var privatePort: UInt16
        var publicPort: UInt16
        var lifetime: UInt32
    }

    enum ResponseError: Error, Equatable {
        case malformed
        case resultCode(UInt16)
    }

    static let serverPort: UInt16 = 5351
    /// Proton keeps a mapping for 60 s; renew well before it runs out.
    static let lifetime: UInt32 = 60
    static let renewInterval: TimeInterval = 45

    /// 12-byte mapping request: version 0, opcode, 2 reserved bytes,
    /// private port, suggested public port, lifetime (all big-endian).
    static func mappingRequest(proto: Proto, privatePort: UInt16,
                               publicPort: UInt16, lifetime: UInt32) -> [UInt8] {
        var bytes: [UInt8] = [0, proto.rawValue, 0, 0]
        bytes += be16(privatePort)
        bytes += be16(publicPort)
        bytes += be32(lifetime)
        return bytes
    }

    /// 16-byte mapping response: version 0, opcode 128 + request opcode,
    /// result code, epoch, private port, mapped public port, lifetime.
    static func parseMappingResponse(_ bytes: [UInt8],
                                     expecting proto: Proto) -> Result<Mapping, ResponseError> {
        guard bytes.count >= 16, bytes[0] == 0,
              bytes[1] == 128 + proto.rawValue else { return .failure(.malformed) }
        let result = read16(bytes, 2)
        guard result == 0 else { return .failure(.resultCode(result)) }
        return .success(Mapping(proto: proto,
                                privatePort: read16(bytes, 8),
                                publicPort: read16(bytes, 10),
                                lifetime: read32(bytes, 12)))
    }

    static func describe(_ error: ResponseError) -> String {
        switch error {
        case .malformed: return "unexpected NAT-PMP answer"
        case .resultCode(1): return "NAT-PMP version not supported"
        case .resultCode(2): return "port forwarding refused (not enabled for this server?)"
        case .resultCode(3): return "gateway has no public address"
        case .resultCode(4): return "gateway is out of ports"
        case .resultCode(5): return "NAT-PMP opcode not supported"
        case .resultCode(let code): return "NAT-PMP error \(code)"
        }
    }

    /// Without an explicit gateway, use x.y.z.1 of the tunnel address
    /// (Proton VPN: 10.2.0.2 → 10.2.0.1).
    static func gateway(override: String, tunnelIP: String?) -> String? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return isIPv4(trimmed) ? trimmed : nil }
        guard let tunnelIP, isIPv4(tunnelIP) else { return nil }
        let parts = tunnelIP.split(separator: ".")
        return parts.prefix(3).joined(separator: ".") + ".1"
    }

    static func isIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isNumber) && (Int($0) ?? 256) <= 255
        }
    }

    private static func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
    private static func be32(_ v: UInt32) -> [UInt8] {
        [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
    }
    private static func read16(_ b: [UInt8], _ i: Int) -> UInt16 {
        UInt16(b[i]) << 8 | UInt16(b[i + 1])
    }
    private static func read32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3])
    }
}

#if canImport(Darwin)
/// Sends NAT-PMP requests through the tunnel interface only, so the
/// request can never go out on Wi-Fi.
enum NATPMPClient {
    enum Failure: Error {
        case badGateway
        case socket(String)
        case noAnswer
        case response(NATPMP.ResponseError)

        var text: String {
            switch self {
            case .badGateway: return "no usable NAT-PMP gateway"
            case .socket(let why): return "socket error: \(why)"
            case .noAnswer: return "gateway did not answer (does this VPN server offer port forwarding?)"
            case .response(let error): return NATPMP.describe(error)
            }
        }
    }

    /// Same requests as Proton's own guide (`natpmpc -a 1 0 udp 60` and
    /// `... tcp 60`): Proton picks the port and keeps it while it is renewed.
    /// The TCP answer carries the port qBittorrent should listen on.
    static func mapPort(gateway: String, interface: String) -> Result<UInt16, Failure> {
        switch request(.udp, gateway: gateway, interface: interface) {
        case .failure(let failure):
            return .failure(failure)
        case .success:
            return request(.tcp, gateway: gateway, interface: interface).map(\.publicPort)
        }
    }

    static func request(_ proto: NATPMP.Proto,
                        gateway: String, interface: String) -> Result<NATPMP.Mapping, Failure> {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = NATPMP.serverPort.bigEndian
        guard inet_pton(AF_INET, gateway, &addr.sin_addr) == 1 else { return .failure(.badGateway) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failure(.socket(String(cString: strerror(errno)))) }
        defer { close(fd) }

        var index = if_nametoindex(interface)
        guard index != 0,
              setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &index,
                         socklen_t(MemoryLayout<UInt32>.size)) == 0 else {
            return .failure(.socket("cannot bind to \(interface)"))
        }

        let payload = NATPMP.mappingRequest(proto: proto, privatePort: 0,
                                            publicPort: 1, lifetime: NATPMP.lifetime)
        // RFC 6886 retry pattern, shortened: 250 ms, 500 ms, 1 s.
        var waitMs = 250
        for _ in 0..<3 {
            var timeout = timeval(tv_sec: waitMs / 1000, tv_usec: Int32((waitMs % 1000) * 1000))
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            let sent = payload.withUnsafeBytes { raw in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == payload.count else {
                return .failure(.socket(String(cString: strerror(errno))))
            }
            var buffer = [UInt8](repeating: 0, count: 64)
            var from = sockaddr_in()
            var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let got = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &from) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &fromLen)
                    }
                }
            }
            if got > 0, from.sin_addr.s_addr == addr.sin_addr.s_addr {
                return NATPMP.parseMappingResponse(Array(buffer.prefix(got)), expecting: proto)
                    .mapError { Failure.response($0) }
            }
            waitMs *= 2
        }
        return .failure(.noAnswer)
    }
}
#endif
