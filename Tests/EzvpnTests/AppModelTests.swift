import NetworkExtension
import TunnelCore
import XCTest
@testable import ezvpn

@MainActor
final class AppModelTests: XCTestCase {
    func testVPNStatusOperationClassification() {
        XCTAssertFalse(NEVPNStatus.invalid.isInOperation)
        XCTAssertFalse(NEVPNStatus.disconnected.isInOperation)
        XCTAssertTrue(NEVPNStatus.connecting.isInOperation)
        XCTAssertTrue(NEVPNStatus.connected.isInOperation)
        XCTAssertTrue(NEVPNStatus.reasserting.isInOperation)
        XCTAssertTrue(NEVPNStatus.disconnecting.isInOperation)
    }

    func testVPNStatusDisplayText() {
        XCTAssertEqual(NEVPNStatus.invalid.displayText, "Not configured")
        XCTAssertEqual(NEVPNStatus.disconnected.displayText, "Disconnected")
        XCTAssertEqual(NEVPNStatus.connecting.displayText, "Connecting…")
        XCTAssertEqual(NEVPNStatus.connected.displayText, "Connected")
        XCTAssertEqual(NEVPNStatus.reasserting.displayText, "Reconnecting…")
        XCTAssertEqual(NEVPNStatus.disconnecting.displayText, "Disconnecting…")
    }

    func testMenuBarIconStateTracksEstablishedVPN() {
        XCTAssertEqual(MenuBarIconState.resolve(statuses: []), .disconnected)
        XCTAssertEqual(
            MenuBarIconState.resolve(statuses: [.invalid, .disconnected, .connecting]),
            .disconnected
        )
        XCTAssertEqual(MenuBarIconState.resolve(statuses: [.connected]), .connected)
        XCTAssertEqual(MenuBarIconState.resolve(statuses: [.reasserting]), .connected)
        XCTAssertEqual(
            MenuBarIconState.resolve(statuses: [.disconnected, .connected]),
            .connected
        )
    }

    func testMenuBarIconStateProvidesAssetAndAccessibilityLabels() {
        XCTAssertEqual(MenuBarIconState.disconnected.imageName, "MenuBarIcon")
        XCTAssertEqual(MenuBarIconState.disconnected.accessibilityLabel, "ezvpn, disconnected")
        XCTAssertEqual(MenuBarIconState.connected.imageName, "MenuBarConnectedIcon")
        XCTAssertEqual(MenuBarIconState.connected.accessibilityLabel, "ezvpn, connected")
    }

    func testManagerErrorsHaveUserFacingDescriptions() {
        XCTAssertEqual(TunnelsManagerError.nameEmpty.errorDescription, "Name can't be empty.")
        XCTAssertEqual(
            TunnelsManagerError.nameDuplicate.errorDescription,
            "A profile with that name already exists."
        )
    }

    func testProfileIDRequiresValidUUID() {
        XCTAssertNil(TunnelContainer.profileID(of: makeManager(configuration: [:])))
        XCTAssertNil(
            TunnelContainer.profileID(
                of: makeManager(configuration: [ProviderConfigKey.profileID: "not-a-uuid"])
            )
        )

        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        XCTAssertEqual(
            TunnelContainer.profileID(
                of: makeManager(configuration: [ProviderConfigKey.profileID: id.uuidString])
            ),
            id
        )

        let managerWithoutCredential = makeManager(
            configuration: [ProviderConfigKey.profileID: id.uuidString],
            passwordReference: nil
        )
        XCTAssertNil(TunnelContainer.profileID(of: managerWithoutCredential))
    }

    func testContainerInitializesFromManagerAndDecodesProfile() throws {
        let profile = TunnelProfile(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Configuration name is not authoritative",
            serverNodeID: "node-id",
            authKeyID: "key-1",
            relayURLs: ["relay"],
            routes: ["10.0.0.0/8"],
            routes6: ["fd00::/8"],
            dnsServers: ["10.0.0.53"],
            dnsMatchDomains: ["corp.example"]
        )
        let manager = makeManager(
            name: "Localized Name",
            configuration: profile.providerConfiguration()
        )

        let container = try XCTUnwrap(TunnelContainer(manager: manager))

        XCTAssertEqual(container.id, profile.id)
        XCTAssertEqual(container.name, "Localized Name")
        XCTAssertTrue(container.manager === manager)
        XCTAssertEqual(container.profile?.id, profile.id)
        XCTAssertEqual(container.profile?.name, "Localized Name")
        XCTAssertEqual(container.profile?.serverNodeID, "node-id")
        XCTAssertEqual(container.profile?.authKeyID, "key-1")
        XCTAssertEqual(container.profile?.dnsMatchDomains, ["corp.example"])
    }

    func testContainerRejectsManagerWithoutStableIdentity() {
        XCTAssertNil(TunnelContainer(manager: makeManager(configuration: [:])))
    }

    func testAuthKeyKeychainRoundTripAndUpdate() throws {
        let id = UUID()
        let storage = InMemoryAuthKeyKeychain()
        let client = storage.client
        defer { try? AuthKeyKeychain.delete(for: id, client: client) }

        let firstReference = try AuthKeyKeychain.store(
            "ed25519-sec:first", for: id, client: client)
        XCTAssertFalse(firstReference.isEmpty)
        XCTAssertEqual(
            try AuthKeyKeychain.secret(forProfileID: id, client: client),
            "ed25519-sec:first"
        )
        #if os(iOS)
        XCTAssertEqual(
            try AuthKeyKeychain.secret(for: firstReference, client: client),
            "ed25519-sec:first"
        )
        #endif

        let updatedReference = try AuthKeyKeychain.store(
            "ed25519-sec:updated", for: id, client: client)
        XCTAssertEqual(updatedReference, firstReference)
        XCTAssertEqual(
            try AuthKeyKeychain.secret(forProfileID: id, client: client),
            "ed25519-sec:updated"
        )

        try AuthKeyKeychain.delete(for: id, client: client)
        XCTAssertThrowsError(
            try AuthKeyKeychain.secret(forProfileID: id, client: client))
    }

    func testRelayTokenCoexistsWithAuthKeyUnderSameProfile() throws {
        let id = UUID()
        let storage = InMemoryAuthKeyKeychain()
        let client = storage.client
        let relay = AuthKeyKeychain.relayService
        defer {
            try? AuthKeyKeychain.delete(for: id, client: client)
            try? AuthKeyKeychain.delete(for: id, service: relay, client: client)
        }

        _ = try AuthKeyKeychain.store("ed25519-sec:key", for: id, client: client)
        _ = try AuthKeyKeychain.store(
            "relay-token", for: id, service: relay, client: client)

        // The two secrets are independent despite sharing the profile id.
        XCTAssertEqual(
            try AuthKeyKeychain.secret(forProfileID: id, client: client),
            "ed25519-sec:key")
        XCTAssertEqual(
            try AuthKeyKeychain.secret(forProfileID: id, service: relay, client: client),
            "relay-token")

        // Deleting the relay secret leaves the auth key intact.
        try AuthKeyKeychain.delete(for: id, service: relay, client: client)
        XCTAssertThrowsError(
            try AuthKeyKeychain.secret(forProfileID: id, service: relay, client: client))
        XCTAssertEqual(
            try AuthKeyKeychain.secret(forProfileID: id, client: client),
            "ed25519-sec:key")
    }

    func testAttachReplacesManagerButPreservesFallbackName() throws {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let configuration = [ProviderConfigKey.profileID: id.uuidString]
        let original = makeManager(name: "Original", configuration: configuration)
        let replacement = makeManager(name: nil, configuration: configuration)
        let container = try XCTUnwrap(TunnelContainer(manager: original))

        container.attach(replacement)

        XCTAssertTrue(container.manager === replacement)
        XCTAssertEqual(container.name, "Original")
    }

    private func makeManager(
        name: String? = nil,
        configuration: [String: Any],
        passwordReference: Data? = Data([0x01])
    ) -> NETunnelProviderManager {
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.example.PacketTunnel"
        proto.serverAddress = "node"
        proto.providerConfiguration = configuration
        proto.passwordReference = passwordReference

        let manager = NETunnelProviderManager()
        manager.localizedDescription = name
        manager.protocolConfiguration = proto
        return manager
    }
}
