import XCTest
@testable import SurfsharkGuard

final class LeakTestTests: XCTestCase {

    func testVerdicts() {
        XCTAssertEqual(LeakTest.verdict(tunnelInterface: nil, tunnelIP: nil, physicalIP: "1.2.3.4"), .noTunnel)
        XCTAssertEqual(LeakTest.verdict(tunnelInterface: "utun3", tunnelIP: nil, physicalIP: "1.2.3.4"), .tunnelUnreachable)
        XCTAssertEqual(LeakTest.verdict(tunnelInterface: "utun3", tunnelIP: "5.6.7.8", physicalIP: nil), .sealedBlocked)
        XCTAssertEqual(LeakTest.verdict(tunnelInterface: "utun3", tunnelIP: "5.6.7.8", physicalIP: "1.2.3.4"), .sealed)
        XCTAssertEqual(LeakTest.verdict(tunnelInterface: "utun3", tunnelIP: "1.2.3.4", physicalIP: "1.2.3.4"), .leak)
    }

    func testParsePublicIPv4() {
        XCTAssertEqual(LeakTest.parsePublicIPv4("203.0.113.7\n"), "203.0.113.7")
        XCTAssertEqual(LeakTest.parsePublicIPv4("  8.8.8.8 "), "8.8.8.8")
        XCTAssertNil(LeakTest.parsePublicIPv4(""))
        XCTAssertNil(LeakTest.parsePublicIPv4("<html>login</html>"))
        XCTAssertNil(LeakTest.parsePublicIPv4("256.1.1.1"))
        XCTAssertNil(LeakTest.parsePublicIPv4("1.2.3"))
        XCTAssertNil(LeakTest.parsePublicIPv4("1..2.3"))
        XCTAssertNil(LeakTest.parsePublicIPv4("2001:db8::1"))
    }

    func testPhysicalInterfaceFromNetstat() {
        XCTAssertEqual(
            LeakTest.physicalInterface(netstatText: fixtureNetstat, ifconfigText: fixtureIfconfig),
            "en0")
    }

    func testPhysicalInterfaceSkipsTunnelDefault() {
        let netstat = """
        Destination        Gateway            Flags               Netif Expire
        default            link#22            UCSg                utun4
        default            192.168.1.1        UGScIg               en1
        """
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        XCTAssertEqual(LeakTest.physicalInterface(netstatText: netstat, ifconfigText: ""), "en1")
    }

    func testPhysicalInterfaceFallsBackToIfconfig() {
        XCTAssertEqual(LeakTest.physicalInterface(netstatText: "", ifconfigText: fixtureIfconfig), "en0")
        XCTAssertNil(LeakTest.physicalInterface(netstatText: "", ifconfigText: ""))
    }

    func testPhysicalInterfaceFilter() {
        XCTAssertTrue(LeakTest.isPhysicalInterface("en0"))
        XCTAssertFalse(LeakTest.isPhysicalInterface("utun4"))
        XCTAssertFalse(LeakTest.isPhysicalInterface("lo0"))
        XCTAssertFalse(LeakTest.isPhysicalInterface("bridge100"))
        XCTAssertFalse(LeakTest.isPhysicalInterface("awdl0"))
    }
}
