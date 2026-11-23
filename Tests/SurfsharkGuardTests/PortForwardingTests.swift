import XCTest
@testable import SurfsharkGuard

final class PortForwardingTests: XCTestCase {
    func testMappingRequestMatchesProtonGuide() {
        // natpmpc -a 1 0 udp 60
        XCTAssertEqual(
            NATPMP.mappingRequest(proto: .udp, privatePort: 0, publicPort: 1, lifetime: 60),
            [0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 60]
        )
        XCTAssertEqual(
            NATPMP.mappingRequest(proto: .tcp, privatePort: 0x1234, publicPort: 0xBEEF,
                                  lifetime: 0x01020304),
            [0, 2, 0, 0, 0x12, 0x34, 0xBE, 0xEF, 1, 2, 3, 4]
        )
    }

    func testParsesMappingResponse() {
        let tcp: [UInt8] = [0, 130, 0, 0, 0, 0, 0x10, 0x00, 0, 0, 0xD4, 0x31, 0, 0, 0, 60]
        XCTAssertEqual(
            try NATPMP.parseMappingResponse(tcp, expecting: .tcp).get(),
            NATPMP.Mapping(proto: .tcp, privatePort: 0, publicPort: 54321, lifetime: 60)
        )
    }

    func testRejectsBadResponses() {
        let refused: [UInt8] = [0, 129, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(NATPMP.parseMappingResponse(refused, expecting: .udp),
                       .failure(.resultCode(2)))
        let wrongOpcode: [UInt8] = [0, 129, 0, 0, 0, 0, 0, 0, 0, 0, 0x30, 0x39, 0, 0, 0, 60]
        XCTAssertEqual(NATPMP.parseMappingResponse(wrongOpcode, expecting: .tcp),
                       .failure(.malformed))
        XCTAssertEqual(NATPMP.parseMappingResponse([0, 129, 0, 0], expecting: .udp),
                       .failure(.malformed))
    }

    func testGatewayGuess() {
        XCTAssertEqual(NATPMP.gateway(override: "", tunnelIP: "10.2.0.2"), "10.2.0.1")
        XCTAssertEqual(NATPMP.gateway(override: " 10.9.8.7 ", tunnelIP: "10.2.0.2"), "10.9.8.7")
        XCTAssertNil(NATPMP.gateway(override: "proton", tunnelIP: "10.2.0.2"))
        XCTAssertNil(NATPMP.gateway(override: "", tunnelIP: nil))
        XCTAssertNil(NATPMP.gateway(override: "", tunnelIP: "fd00::2"))
        XCTAssertNil(NATPMP.gateway(override: "10.2.0.256", tunnelIP: nil))
    }
}
