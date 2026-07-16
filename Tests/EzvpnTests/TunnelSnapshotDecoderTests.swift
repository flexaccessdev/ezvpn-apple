import Foundation
import XCTest
@testable import ezvpn

final class TunnelSnapshotDecoderTests: XCTestCase {
    func testRuntimeInfoDecodesCompleteReply() throws {
        let data = Data(#"""
        {
          "assigned_ip": "10.0.0.2",
          "assigned_ip6": "fd00::2",
          "mtu": 1280,
          "included_routes": ["10.0.0.0/8"],
          "included_routes6": ["fd00::/8"],
          "bypass_routes": ["203.0.113.1/32"],
          "bypass_routes6": ["2001:db8::1/128"],
          "dns_servers": ["10.0.0.53"],
          "dns_match_domains": ["corp.example"]
        }
        """#.utf8)

        let info = try XCTUnwrap(TunnelSnapshotDecoder.runtimeInfo(from: data))

        XCTAssertEqual(info.assignedIP, "10.0.0.2")
        XCTAssertEqual(info.assignedIP6, "fd00::2")
        XCTAssertEqual(info.mtu, 1280)
        XCTAssertEqual(info.includedRoutes, ["10.0.0.0/8"])
        XCTAssertEqual(info.includedRoutes6, ["fd00::/8"])
        XCTAssertEqual(info.bypassRoutes, ["203.0.113.1/32"])
        XCTAssertEqual(info.bypassRoutes6, ["2001:db8::1/128"])
        XCTAssertEqual(info.dnsServers, ["10.0.0.53"])
        XCTAssertEqual(info.dnsMatchDomains, ["corp.example"])
    }

    func testRuntimeInfoDefaultsMissingCollectionsToEmpty() throws {
        let info = try XCTUnwrap(
            TunnelSnapshotDecoder.runtimeInfo(from: Data(#"{"assigned_ip":"10.0.0.2"}"#.utf8))
        )

        XCTAssertEqual(info.assignedIP, "10.0.0.2")
        XCTAssertNil(info.assignedIP6)
        XCTAssertNil(info.mtu)
        XCTAssertTrue(info.includedRoutes.isEmpty)
        XCTAssertTrue(info.includedRoutes6.isEmpty)
        XCTAssertTrue(info.bypassRoutes.isEmpty)
        XCTAssertTrue(info.bypassRoutes6.isEmpty)
        XCTAssertTrue(info.dnsServers.isEmpty)
        XCTAssertTrue(info.dnsMatchDomains.isEmpty)
    }

    func testRuntimeInfoRejectsMalformedOrNonObjectJSON() {
        XCTAssertNil(TunnelSnapshotDecoder.runtimeInfo(from: Data("not-json".utf8)))
        XCTAssertNil(TunnelSnapshotDecoder.runtimeInfo(from: Data("[]".utf8)))
    }

    func testConnectionPathsDecodeKnownAndUnknownKinds() {
        let data = Data(#"""
        {
          "paths": [
            {"kind":"direct", "display":"Direct 192.0.2.1:443", "selected":true},
            {"kind":"relay", "display":"Relay https://relay.example", "selected":false},
            {"kind":"future", "display":"Future transport"},
            {"kind":"direct", "selected":true}
          ]
        }
        """#.utf8)

        let paths = TunnelSnapshotDecoder.connectionPaths(from: data)

        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths.map(\.kind), [.direct, .relay, .other])
        XCTAssertEqual(
            paths.map(\.display),
            ["Direct 192.0.2.1:443", "Relay https://relay.example", "Future transport"]
        )
        XCTAssertEqual(paths.map(\.selected), [true, false, false])
    }

    func testConnectionPathsReturnEmptyForMalformedReplies() {
        XCTAssertEqual(TunnelSnapshotDecoder.connectionPaths(from: Data("{}".utf8)).count, 0)
        XCTAssertEqual(TunnelSnapshotDecoder.connectionPaths(from: Data("bad".utf8)).count, 0)
    }
}
