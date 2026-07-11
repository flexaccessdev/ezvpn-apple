import XCTest
@testable import TunnelCore

final class SplitDNSTests: XCTestCase {
    // MARK: isIPAddressLiteral

    func testIPLiterals() {
        XCTAssertTrue(isIPAddressLiteral("10.22.33.10"))
        XCTAssertTrue(isIPAddressLiteral("fd00::1"))
        XCTAssertFalse(isIPAddressLiteral("dns.local.example.com"))
        XCTAssertFalse(isIPAddressLiteral("10.22.33"))
        XCTAssertFalse(isIPAddressLiteral(""))
    }

    // MARK: normalizedDNSMatchDomain

    func testNormalizationStripsDotsAndCase() {
        XCTAssertEqual(normalizedDNSMatchDomain(".Local.Example.COM"), "local.example.com")
        XCTAssertEqual(normalizedDNSMatchDomain("local.example.com."), "local.example.com")
        XCTAssertEqual(normalizedDNSMatchDomain("  local.example.com "), "local.example.com")
        XCTAssertEqual(normalizedDNSMatchDomain("local.example.com"), "local.example.com")
    }

    // MARK: splitDNSValidationError

    func testEmptyConfigIsValid() {
        XCTAssertNil(splitDNSValidationError(servers: [], matchDomains: []))
    }

    func testMatchDomainsWithoutServersRejected() {
        XCTAssertNotNil(splitDNSValidationError(
            servers: [], matchDomains: ["local.example.com"]))
    }

    func testServersWithoutMatchDomainsAllowed() {
        // All-DNS-through-tunnel is a legitimate configuration.
        XCTAssertNil(splitDNSValidationError(servers: ["10.22.33.10"], matchDomains: []))
    }

    func testHostnameServerRejected() {
        XCTAssertNotNil(splitDNSValidationError(
            servers: ["dns.local.example.com"], matchDomains: ["local.example.com"]))
    }

    func testJunkMatchDomainRejected() {
        XCTAssertNotNil(splitDNSValidationError(
            servers: ["10.22.33.10"], matchDomains: ["local example.com"]))
        XCTAssertNotNil(splitDNSValidationError(
            servers: ["10.22.33.10"], matchDomains: ["10.0.0.0/8"]))
        XCTAssertNotNil(splitDNSValidationError(
            servers: ["10.22.33.10"], matchDomains: [""]))
    }

    func testValidSplitDNSConfig() {
        XCTAssertNil(splitDNSValidationError(
            servers: ["10.22.33.10", "fd00::53"],
            matchDomains: ["local.example.com"]))
    }

    // MARK: dnsServersOutsideRoutes

    func testServerInsideV4RouteIsCovered() {
        XCTAssertEqual(dnsServersOutsideRoutes(
            servers: ["10.22.33.10"], routes: ["10.22.32.0/20"], routes6: []), [])
    }

    func testServerOutsideV4RouteIsReported() {
        XCTAssertEqual(dnsServersOutsideRoutes(
            servers: ["10.22.48.10"], routes: ["10.22.32.0/20"], routes6: []),
            ["10.22.48.10"])
    }

    func testV6ServerCheckedAgainstV6Routes() {
        XCTAssertEqual(dnsServersOutsideRoutes(
            servers: ["fd00::53"], routes: ["10.22.32.0/20"], routes6: ["fd00::/64"]), [])
        XCTAssertEqual(dnsServersOutsideRoutes(
            servers: ["fd01::53"], routes: [], routes6: ["fd00::/64"]), ["fd01::53"])
    }

    func testGatewayHostRouteCoversServer() {
        // The provider passes applied routes, which include the /32 gateway
        // host route — a DNS server on the gateway itself is covered.
        XCTAssertEqual(dnsServersOutsideRoutes(
            servers: ["10.124.0.1"], routes: ["10.124.0.1/32"], routes6: []), [])
    }

    func testUnparseableServerIsReported() {
        XCTAssertEqual(dnsServersOutsideRoutes(
            servers: ["not-an-ip"], routes: ["10.0.0.0/8"], routes6: []), ["not-an-ip"])
    }
}
