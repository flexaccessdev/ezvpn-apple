import XCTest
@testable import TunnelCore

final class IPPrefixTests: XCTestCase {
    // MARK: - ipv4Bits / ipv4String / ipv4Mask

    func testIPv4BitsRoundTrip() {
        XCTAssertEqual(ipv4Bits("192.168.1.23"), 0xc0a80117)
        XCTAssertEqual(ipv4String(0xc0a80117), "192.168.1.23")
        XCTAssertEqual(ipv4Bits("0.0.0.0"), 0)
        XCTAssertEqual(ipv4Bits("255.255.255.255"), ~UInt32(0))
    }

    func testIPv4BitsRejectsMalformed() {
        XCTAssertNil(ipv4Bits("192.168.1"))
        XCTAssertNil(ipv4Bits("192.168.1.256"))
        XCTAssertNil(ipv4Bits("192.168.1.x"))
        XCTAssertNil(ipv4Bits(""))
    }

    func testIPv4Mask() {
        XCTAssertEqual(ipv4Mask(0), "0.0.0.0")
        XCTAssertEqual(ipv4Mask(8), "255.0.0.0")
        XCTAssertEqual(ipv4Mask(12), "255.240.0.0")
        XCTAssertEqual(ipv4Mask(24), "255.255.255.0")
        XCTAssertEqual(ipv4Mask(32), "255.255.255.255")
    }

    // MARK: - ipv6Network

    func testIPv6NetworkZeroesHostBits() {
        XCTAssertEqual(ipv6Network("fd12:3456:789a::42", prefix: 48), "fd12:3456:789a::")
        XCTAssertEqual(ipv6Network("fd12:3456:789a:bcde::1", prefix: 64), "fd12:3456:789a:bcde::")
        // Non-nibble-aligned prefix: /10 keeps fe80's top bits only.
        XCTAssertEqual(ipv6Network("febf::1", prefix: 10), "fe80::")
        XCTAssertEqual(ipv6Network("fd00::1", prefix: 128), "fd00::1")
        XCTAssertEqual(ipv6Network("fd00::1", prefix: 0), "::")
    }

    func testIPv6NetworkRejectsMalformed() {
        XCTAssertNil(ipv6Network("not-an-address", prefix: 64))
        XCTAssertNil(ipv6Network("192.168.1.1", prefix: 64))
    }

    // MARK: - parseCIDR

    func testParseCIDR() throws {
        let v4 = try XCTUnwrap(parseCIDR("10.0.0.0/8", family: AF_INET))
        XCTAssertEqual(v4.bytes, [10, 0, 0, 0])
        XCTAssertEqual(v4.prefix, 8)

        let v6 = try XCTUnwrap(parseCIDR("fd00::/8", family: AF_INET6))
        XCTAssertEqual(v6.bytes.count, 16)
        XCTAssertEqual(v6.bytes[0], 0xfd)
        XCTAssertEqual(v6.prefix, 8)
    }

    func testParseCIDRRejectsMalformed() {
        XCTAssertNil(parseCIDR("10.0.0.0", family: AF_INET), "missing prefix")
        XCTAssertNil(parseCIDR("10.0.0.0/33", family: AF_INET), "prefix too long")
        XCTAssertNil(parseCIDR("10.0.0.0/-1", family: AF_INET), "negative prefix")
        XCTAssertNil(parseCIDR("10.0.0.0/8", family: AF_INET6), "family mismatch")
        XCTAssertNil(parseCIDR("fd00::/129", family: AF_INET6), "v6 prefix too long")
        XCTAssertNil(parseCIDR("fd00::/8/9", family: AF_INET6), "extra slash")
        XCTAssertNil(parseCIDR("garbage/8", family: AF_INET), "bad address")
    }

    // MARK: - prefixesOverlap

    private func overlap(_ x: String, _ y: String, family: Int32 = AF_INET) -> Bool {
        guard let a = parseCIDR(x, family: family), let b = parseCIDR(y, family: family) else {
            XCTFail("fixture CIDR failed to parse: \(x) or \(y)")
            return false
        }
        return prefixesOverlap(a.bytes, a.prefix, b.bytes, b.prefix)
    }

    func testOverlapContainment() {
        XCTAssertTrue(overlap("10.0.0.0/8", "10.1.2.0/24"))
        XCTAssertTrue(overlap("10.1.2.0/24", "10.0.0.0/8"), "order-independent")
        XCTAssertTrue(overlap("192.168.1.128/25", "192.168.1.0/24"))
        XCTAssertTrue(overlap("10.0.0.0/8", "10.0.0.0/8"), "identical prefixes")
    }

    func testOverlapDisjoint() {
        XCTAssertFalse(overlap("10.0.0.0/8", "192.168.1.0/24"))
        XCTAssertFalse(overlap("192.168.1.0/24", "192.168.2.0/24"), "adjacent /24s")
        XCTAssertFalse(overlap("192.168.1.0/25", "192.168.1.128/25"), "sibling /25s")
    }

    func testOverlapNonOctetAlignedBoundary() {
        XCTAssertTrue(overlap("172.16.0.0/12", "172.31.0.0/16"), "inside the /12")
        XCTAssertFalse(overlap("172.16.0.0/12", "172.32.0.0/16"), "just past the /12")
    }

    func testOverlapDefaultRouteMatchesEverything() {
        XCTAssertTrue(overlap("0.0.0.0/0", "192.168.1.0/24"))
        XCTAssertTrue(overlap("::/0", "2001:db8::/32", family: AF_INET6))
    }

    func testOverlapIPv6() {
        XCTAssertTrue(overlap("fd00::/8", "fd12:3456::/32", family: AF_INET6))
        XCTAssertFalse(overlap("fd00::/8", "fe80::/10", family: AF_INET6))
    }

    // MARK: - leadingOnes

    func testLeadingOnes() {
        XCTAssertEqual(leadingOnes([255, 255, 255, 0]), 24)
        XCTAssertEqual(leadingOnes([255, 255, 255, 255]), 32)
        XCTAssertEqual(leadingOnes([255, 240, 0, 0]), 12)
        XCTAssertEqual(leadingOnes([0, 0, 0, 0]), 0)
        XCTAssertEqual(leadingOnes(Array(repeating: 255, count: 16)), 128)
        XCTAssertEqual(leadingOnes([255, 255, 255, 255, 255, 255, 255, 255,
                                    0, 0, 0, 0, 0, 0, 0, 0]), 64)
    }

    // MARK: - cidrDescription

    func testCidrDescriptionZeroesHostBits() {
        XCTAssertEqual(cidrDescription([192, 168, 1, 23], 24), "192.168.1.0/24")
        XCTAssertEqual(cidrDescription([192, 168, 1, 23], 32), "192.168.1.23/32")
        XCTAssertEqual(cidrDescription([172, 31, 5, 9], 12), "172.16.0.0/12")
        let v6 = parseCIDR("fd12:3456:789a::42/48", family: AF_INET6)!
        XCTAssertEqual(cidrDescription(v6.bytes, v6.prefix), "fd12:3456:789a::/48")
    }
}

final class SplitTunnelConflictTests: XCTestCase {
    /// A device on 192.168.1.0/24 Wi-Fi with a ULA /64, like a home network.
    private let home: [LocalNetwork] = [
        LocalNetwork(interface: "en0", bytes: [192, 168, 1, 23], prefix: 24),
        LocalNetwork(interface: "en0",
                     bytes: parseCIDR("fd12:3456:789a:1::23/64", family: AF_INET6)!.bytes,
                     prefix: 64),
    ]

    func testNoConflict() {
        XCTAssertNil(splitTunnelConflict(
            routes: ["10.0.0.0/8"], routes6: ["fd99::/64"], localNetworks: home))
        XCTAssertNil(splitTunnelConflict(routes: [], routes6: [], localNetworks: home))
    }

    func testIPv4Conflict() throws {
        let msg = try XCTUnwrap(splitTunnelConflict(
            routes: ["192.168.0.0/16"], routes6: [], localNetworks: home))
        XCTAssertTrue(msg.contains("192.168.0.0/16"), msg)
        XCTAssertTrue(msg.contains("192.168.1.0/24"), "local net host bits zeroed: \(msg)")
        XCTAssertTrue(msg.contains("en0"), msg)
    }

    func testIPv6Conflict() throws {
        let msg = try XCTUnwrap(splitTunnelConflict(
            routes: [], routes6: ["fd12:3456:789a::/48"], localNetworks: home))
        XCTAssertTrue(msg.contains("fd12:3456:789a::/48"), msg)
        XCTAssertTrue(msg.contains("en0"), msg)
    }

    func testFamiliesDoNotCrossCheck() {
        // A v4 route can only conflict with v4 locals, v6 with v6.
        XCTAssertNil(splitTunnelConflict(
            routes: ["10.0.0.0/8"], routes6: [],
            localNetworks: [LocalNetwork(
                interface: "en0",
                bytes: parseCIDR("fd00::1/64", family: AF_INET6)!.bytes, prefix: 64)]))
    }

    func testDefaultRouteAlwaysConflicts() {
        XCTAssertNotNil(splitTunnelConflict(
            routes: ["0.0.0.0/0"], routes6: [], localNetworks: home))
        XCTAssertNotNil(splitTunnelConflict(
            routes: [], routes6: ["::/0"], localNetworks: home))
    }

    func testMalformedRoutesAreSkipped() {
        XCTAssertNil(splitTunnelConflict(
            routes: ["not-a-cidr", "192.168.1.0"], routes6: ["fd00::"],
            localNetworks: home))
    }

    func testFirstConflictWins() throws {
        let msg = try XCTUnwrap(splitTunnelConflict(
            routes: ["10.0.0.0/8", "192.168.0.0/16"], routes6: [],
            localNetworks: home + [LocalNetwork(interface: "en1", bytes: [10, 9, 8, 7], prefix: 16)]))
        XCTAssertTrue(msg.contains("10.0.0.0/8"), "routes checked in order: \(msg)")
    }

    /// The live enumerator must never report loopback, utun, or link-local —
    /// asserted indirectly: no local network may sit inside 127.0.0.0/8 or
    /// fe80::/10. (Interface makeup varies by machine, so only invariants are
    /// checked; the conflict logic itself is covered by the fixtures above.)
    func testLiveLocalNetworksExcludeNonRoutable() {
        for net in localNetworks() {
            XCTAssertFalse(net.interface.hasPrefix("utun"), net.interface)
            XCTAssertFalse(net.interface.hasPrefix("lo"), net.interface)
            if net.bytes.count == 4 {
                XCTAssertNotEqual(net.bytes[0], 127, "loopback leaked: \(net.bytes)")
            } else {
                XCTAssertFalse(net.bytes[0] == 0xfe && net.bytes[1] & 0xc0 == 0x80,
                               "link-local leaked")
            }
        }
    }
}
