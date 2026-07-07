import XCTest
@testable import TunnelCore

final class TunnelProfileTests: XCTestCase {
    private func sample(
        id: UUID = UUID(),
        name: String = "Home",
        relayURLs: [String] = ["https://relay.example"],
        routes: [String] = ["10.0.0.0/8"],
        routes6: [String] = ["fd00::/64"]
    ) -> TunnelProfile {
        TunnelProfile(
            id: id, name: name,
            serverNodeID: "node-abc", authToken: "tok",
            relayURLs: relayURLs, routes: routes, routes6: routes6
        )
    }

    func testProviderConfigurationUsesExtensionKeys() {
        let conf = sample().providerConfiguration()
        // These keys are what PacketTunnelProvider.startTunnel reads.
        XCTAssertEqual(conf["server_node_id"] as? String, "node-abc")
        XCTAssertEqual(conf["auth_token"] as? String, "tok")
        XCTAssertEqual(conf["relay_urls"] as? [String], ["https://relay.example"])
        XCTAssertEqual(conf["routes"] as? [String], ["10.0.0.0/8"])
        XCTAssertEqual(conf["routes6"] as? [String], ["fd00::/64"])
        XCTAssertNotNil(conf["profile_id"] as? String)
        XCTAssertEqual(conf["name"] as? String, "Home")
    }

    func testRoundTripPreservesEverything() {
        let profile = sample()
        let decoded = TunnelProfile.from(
            providerConfiguration: profile.providerConfiguration(),
            name: profile.name
        )
        XCTAssertEqual(decoded, profile)
    }

    func testRoundTripPreservesProfileID() {
        let id = UUID()
        let profile = sample(id: id)
        let decoded = TunnelProfile.from(
            providerConfiguration: profile.providerConfiguration(), name: profile.name)
        XCTAssertEqual(decoded?.id, id)
    }

    func testDecodeUsesPassedNameNotDictName() {
        // localizedDescription is the source of truth for the name; a stale
        // name key in the dict must not win.
        var conf = sample(name: "Old").providerConfiguration()
        conf["name"] = "Stale"
        let decoded = TunnelProfile.from(providerConfiguration: conf, name: "Renamed")
        XCTAssertEqual(decoded?.name, "Renamed")
    }

    func testEmptyArraysRoundTrip() {
        let profile = sample(relayURLs: [], routes: [], routes6: [])
        let decoded = TunnelProfile.from(
            providerConfiguration: profile.providerConfiguration(), name: profile.name)
        XCTAssertEqual(decoded?.relayURLs, [])
        XCTAssertEqual(decoded?.routes, [])
        XCTAssertEqual(decoded?.routes6, [])
    }

    func testMissingOptionalKeysDefaultToEmpty() {
        let conf: [String: Any] = ["profile_id": UUID().uuidString]
        let decoded = TunnelProfile.from(providerConfiguration: conf, name: "Bare")
        XCTAssertEqual(decoded?.serverNodeID, "")
        XCTAssertEqual(decoded?.authToken, "")
        XCTAssertEqual(decoded?.relayURLs, [])
        XCTAssertEqual(decoded?.routes, [])
        XCTAssertEqual(decoded?.routes6, [])
    }

    func testMissingProfileIDFailsDecode() {
        let conf: [String: Any] = ["server_node_id": "x"]
        XCTAssertNil(TunnelProfile.from(providerConfiguration: conf, name: "NoID"))
    }

    func testUnparseableProfileIDFailsDecode() {
        let conf: [String: Any] = ["profile_id": "not-a-uuid"]
        XCTAssertNil(TunnelProfile.from(providerConfiguration: conf, name: "BadID"))
    }
}
