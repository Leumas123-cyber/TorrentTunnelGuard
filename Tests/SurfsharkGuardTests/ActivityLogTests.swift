import XCTest
@testable import SurfsharkGuard

final class ActivityLogTests: XCTestCase {
    func testAppendKeepsOrderAndNewestFirst() {
        var log = ActivityLog()
        log.append(.tunnel, "Tunnel up: utun3")
        log.append(.action, "Binding written")
        XCTAssertEqual(log.entries.map(\.message), ["Tunnel up: utun3", "Binding written"])
        XCTAssertEqual(log.newestFirst.first?.message, "Binding written")
    }

    func testRepeatOfNewestEntryIsSkipped() {
        var log = ActivityLog()
        XCTAssertTrue(log.append(.problem, "qBittorrent is still running"))
        XCTAssertFalse(log.append(.problem, "qBittorrent is still running"))
        XCTAssertTrue(log.append(.status, "No VPN tunnel"))
        XCTAssertTrue(log.append(.problem, "qBittorrent is still running"))
        XCTAssertEqual(log.entries.count, 3)
    }

    func testEmptyMessageIsIgnored() {
        var log = ActivityLog()
        XCTAssertFalse(log.append(.action, "   "))
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testLimitDropsOldest() {
        var log = ActivityLog(limit: 3)
        for i in 1...5 { log.append(.action, "event \(i)") }
        XCTAssertEqual(log.entries.map(\.message), ["event 3", "event 4", "event 5"])
    }

    func testRoundTripAndTrimOnDecode() {
        var log = ActivityLog(limit: 10)
        for i in 1...6 { log.append(.tunnel, "event \(i)") }
        let restored = ActivityLog.decode(log.encoded(), limit: 4)
        XCTAssertEqual(restored.entries.map(\.message),
                       ["event 3", "event 4", "event 5", "event 6"])
    }

    func testDecodeOfGarbageGivesEmptyLog() {
        XCTAssertTrue(ActivityLog.decode(Data("nope".utf8)).entries.isEmpty)
        XCTAssertTrue(ActivityLog.decode(nil).entries.isEmpty)
    }

    func testClear() {
        var log = ActivityLog()
        log.append(.action, "x")
        log.clear()
        XCTAssertTrue(log.entries.isEmpty)
    }

    func testTunnelChangeMessages() {
        XCTAssertEqual(
            tunnelChangeMessage(previousIface: nil, previousIP: nil,
                                currentIface: "utun3", currentIP: "10.8.0.2", firstCheck: true),
            "Started — tunnel is utun3 (10.8.0.2)")
        XCTAssertEqual(
            tunnelChangeMessage(previousIface: nil, previousIP: nil,
                                currentIface: nil, currentIP: nil, firstCheck: true),
            "Started — no VPN tunnel")
        XCTAssertEqual(
            tunnelChangeMessage(previousIface: nil, previousIP: nil,
                                currentIface: "utun3", currentIP: nil, firstCheck: false),
            "Tunnel up: utun3")
        XCTAssertEqual(
            tunnelChangeMessage(previousIface: "utun3", previousIP: "10.8.0.2",
                                currentIface: nil, currentIP: nil, firstCheck: false),
            "Tunnel down (was utun3)")
        XCTAssertEqual(
            tunnelChangeMessage(previousIface: "utun3", previousIP: "10.8.0.2",
                                currentIface: "utun9", currentIP: "10.14.0.2", firstCheck: false),
            "Tunnel moved: utun3 (10.8.0.2) → utun9 (10.14.0.2)")
        XCTAssertEqual(
            tunnelChangeMessage(previousIface: "utun3", previousIP: "10.8.0.2",
                                currentIface: "utun3", currentIP: "10.8.0.7", firstCheck: false),
            "Tunnel IP changed on utun3: 10.8.0.2 → 10.8.0.7")
        XCTAssertNil(
            tunnelChangeMessage(previousIface: "utun3", previousIP: "10.8.0.2",
                                currentIface: "utun3", currentIP: "10.8.0.2", firstCheck: false))
        XCTAssertNil(
            tunnelChangeMessage(previousIface: nil, previousIP: nil,
                                currentIface: nil, currentIP: nil, firstCheck: false))
    }
}
