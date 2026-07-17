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
        XCTAssertEqual(container.profile?.dnsMatchDomains, ["corp.example"])
    }

    func testContainerRejectsManagerWithoutStableIdentity() {
        XCTAssertNil(TunnelContainer(manager: makeManager(configuration: [:])))
    }

    func testAuthTokenKeychainRoundTripAndUpdate() throws {
        let id = UUID()
        let storage = InMemoryAuthTokenKeychain()
        let client = storage.client
        defer { try? AuthTokenKeychain.delete(for: id, client: client) }

        let firstReference = try AuthTokenKeychain.store(
            "first-token", for: id, client: client)
        XCTAssertFalse(firstReference.isEmpty)
        XCTAssertEqual(
            try AuthTokenKeychain.token(forProfileID: id, client: client),
            "first-token"
        )
        #if os(iOS)
        XCTAssertEqual(
            try AuthTokenKeychain.token(for: firstReference, client: client),
            "first-token"
        )
        #endif

        let updatedReference = try AuthTokenKeychain.store(
            "updated-token", for: id, client: client)
        XCTAssertEqual(updatedReference, firstReference)
        XCTAssertEqual(
            try AuthTokenKeychain.token(forProfileID: id, client: client),
            "updated-token"
        )

        try AuthTokenKeychain.delete(for: id, client: client)
        XCTAssertThrowsError(
            try AuthTokenKeychain.token(forProfileID: id, client: client))
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

private final class InMemoryAuthTokenKeychain {
    private struct Item {
        var tokenData: Data
        let persistentReference: Data
    }

    private var items: [String: Item] = [:]

    var client: AuthTokenKeychainClient {
        AuthTokenKeychainClient(
            add: { [unowned self] query in add(query) },
            update: { [unowned self] query, attributes in
                update(query, attributes: attributes)
            },
            copyMatching: { [unowned self] query in copyMatching(query) },
            delete: { [unowned self] query in delete(query) }
        )
    }

    private func add(_ query: [String: Any]) -> AuthTokenKeychainClient.Result {
        guard
            let account = query[kSecAttrAccount as String] as? String,
            let tokenData = query[kSecValueData as String] as? Data
        else {
            return (errSecParam, nil)
        }
        guard items[account] == nil else {
            return (errSecDuplicateItem, nil)
        }

        let reference = Data("persistent-ref:\(account)".utf8)
        items[account] = Item(
            tokenData: tokenData,
            persistentReference: reference
        )
        return (errSecSuccess, reference)
    }

    private func update(
        _ query: [String: Any],
        attributes: [String: Any]
    ) -> OSStatus {
        guard
            let account = query[kSecAttrAccount as String] as? String,
            let tokenData = attributes[kSecValueData as String] as? Data,
            var item = items[account]
        else {
            return errSecItemNotFound
        }

        item.tokenData = tokenData
        items[account] = item
        return errSecSuccess
    }

    private func copyMatching(
        _ query: [String: Any]
    ) -> AuthTokenKeychainClient.Result {
        // Identity query (class + service + account): return the ref or the
        // data, mirroring the real Keychain's kSecReturn* handling. A query
        // with the right account but a mismatched service or class matches
        // nothing.
        if let account = query[kSecAttrAccount as String] as? String {
            let classMatches =
                (query[kSecClass as String] as? String) == (kSecClassGenericPassword as String)
            let serviceMatches =
                (query[kSecAttrService as String] as? String) == AuthTokenKeychain.service
            guard classMatches, serviceMatches, let item = items[account] else {
                return (errSecItemNotFound, nil)
            }
            if query[kSecReturnPersistentRef as String] as? Bool == true {
                return (errSecSuccess, item.persistentReference)
            }
            return (errSecSuccess, item.tokenData)
        }

        // Persistent-reference query (the iOS extension's path).
        let reference = query[kSecValuePersistentRef as String] as? Data
        guard
            let reference,
            let item = items.values.first(where: {
                $0.persistentReference == reference
            })
        else {
            return (errSecItemNotFound, nil)
        }
        return (errSecSuccess, item.tokenData)
    }

    private func delete(_ query: [String: Any]) -> OSStatus {
        guard let account = query[kSecAttrAccount as String] as? String else {
            return errSecParam
        }
        return items.removeValue(forKey: account) == nil
            ? errSecItemNotFound
            : errSecSuccess
    }
}
