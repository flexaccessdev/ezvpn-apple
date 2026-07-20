import TunnelCore
import XCTest
@testable import ezvpn

final class TunnelProfileFormTests: XCTestCase {
    func testRequiredFieldsIgnoreSurroundingWhitespace() {
        var form = TunnelProfileForm()
        XCTAssertFalse(form.hasRequiredFields)

        form.name = "  Home  "
        form.serverNodeID = "\nnode-id\t"
        form.authToken = " token "
        XCTAssertTrue(form.hasRequiredFields)

        form.authToken = " \n\t "
        XCTAssertFalse(form.hasRequiredFields)
    }

    func testMakeSubmissionTrimsScalarsAndSplitsLists() throws {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var form = TunnelProfileForm()
        form.name = "  Office \n"
        form.serverNodeID = " node-id "
        form.authToken = " token "
        form.relayURLs = " https://relay.one , ,\nhttps://relay.two "
        form.routes = " 10.0.0.0/8,192.168.0.0/16 "
        form.routes6 = " fd00::/8, "

        let submission = try form.makeSubmission(id: id, includesDNS: false)
        let profile = submission.profile

        XCTAssertEqual(profile.id, id)
        XCTAssertEqual(profile.name, "Office")
        XCTAssertEqual(profile.serverNodeID, "node-id")
        XCTAssertEqual(submission.authToken, "token")
        XCTAssertEqual(profile.relayURLs, ["https://relay.one", "https://relay.two"])
        XCTAssertEqual(profile.routes, ["10.0.0.0/8", "192.168.0.0/16"])
        XCTAssertEqual(profile.routes6, ["fd00::/8"])
        XCTAssertEqual(profile.dnsServers, [])
        XCTAssertEqual(profile.dnsMatchDomains, [])
    }

    func testMakeSubmissionCarriesRelayTokenWithCustomRelays() throws {
        var form = requiredForm()
        form.relayURLs = " https://relay.one "
        form.relayAuthToken = "  shared-secret  "

        let submission = try form.makeSubmission(id: UUID(), includesDNS: false)

        XCTAssertEqual(submission.profile.relayURLs, ["https://relay.one"])
        // The relay token is a secret kept out of the profile (Keychain-stored).
        XCTAssertEqual(submission.relayAuthToken, "shared-secret")
    }

    func testMakeSubmissionDropsBlankRelayToken() throws {
        var form = requiredForm()
        form.relayURLs = "https://relay.one"
        form.relayAuthToken = "   "

        let submission = try form.makeSubmission(id: UUID(), includesDNS: false)

        XCTAssertNil(submission.relayAuthToken)
    }

    func testMakeSubmissionRejectsRelayTokenWithoutRelays() {
        var form = requiredForm()
        form.relayAuthToken = "shared-secret"

        XCTAssertThrowsError(try form.makeSubmission(id: UUID(), includesDNS: false)) { error in
            XCTAssertEqual(error as? TunnelProfileFormError, .relayTokenWithoutRelays)
        }
    }

    func testMakeSubmissionNormalizesAndValidatesDNS() throws {
        var form = requiredForm()
        form.dnsServers = " 10.0.0.53, fd00::53 "
        form.dnsMatchDomains = " .Corp.Example. , DEV.EXAMPLE "

        let profile = try form.makeSubmission(id: UUID(), includesDNS: true).profile

        XCTAssertEqual(profile.dnsServers, ["10.0.0.53", "fd00::53"])
        XCTAssertEqual(profile.dnsMatchDomains, ["corp.example", "dev.example"])
    }

    func testMakeSubmissionRejectsInvalidDNS() {
        var form = requiredForm()
        form.dnsServers = "resolver.example"

        XCTAssertThrowsError(try form.makeSubmission(id: UUID(), includesDNS: true)) { error in
            XCTAssertEqual(
                error as? TunnelProfileFormError,
                .invalidDNS("DNS server is not an IP address: resolver.example")
            )
            XCTAssertEqual(
                (error as? LocalizedError)?.errorDescription,
                "DNS server is not an IP address: resolver.example"
            )
        }
    }

    func testMakeSubmissionRejectsMissingRequiredFields() {
        var form = requiredForm()
        form.authToken = "   "

        XCTAssertThrowsError(try form.makeSubmission(id: UUID(), includesDNS: true)) { error in
            XCTAssertEqual(error as? TunnelProfileFormError, .missingRequiredFields)
        }
    }

    func testMacOSConversionDropsDNSFields() throws {
        var form = requiredForm()
        form.dnsServers = "not-an-ip"
        form.dnsMatchDomains = "invalid/domain"

        let profile = try form.makeSubmission(id: UUID(), includesDNS: false).profile

        XCTAssertTrue(profile.dnsServers.isEmpty)
        XCTAssertTrue(profile.dnsMatchDomains.isEmpty)
    }

    func testProfileInitializationProducesEditableCSV() {
        let profile = TunnelProfile(
            name: "Home",
            serverNodeID: "node",
            relayURLs: ["relay-1", "relay-2"],
            routes: ["10.0.0.0/8"],
            routes6: ["fd00::/8"],
            dnsServers: ["10.0.0.53"],
            dnsMatchDomains: ["corp.example"]
        )

        let form = TunnelProfileForm(profile: profile, authToken: "secret")

        XCTAssertEqual(form.name, "Home")
        XCTAssertEqual(form.serverNodeID, "node")
        XCTAssertEqual(form.authToken, "secret")
        XCTAssertEqual(form.relayURLs, "relay-1, relay-2")
        XCTAssertEqual(form.routes, "10.0.0.0/8")
        XCTAssertEqual(form.routes6, "fd00::/8")
        XCTAssertEqual(form.dnsServers, "10.0.0.53")
        XCTAssertEqual(form.dnsMatchDomains, "corp.example")
    }

    private func requiredForm() -> TunnelProfileForm {
        var form = TunnelProfileForm()
        form.name = "Home"
        form.serverNodeID = "node"
        form.authToken = "token"
        return form
    }
}
