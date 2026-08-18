import XCTest
@testable import ezvpn

/// Covers the shared auth-key list: the FFI keypair primitives it is built on,
/// and the add/rename/delete rules plus the Keychain round trip.
@MainActor
final class AuthKeyStoreTests: XCTestCase {
    func testGenerateProducesADerivableKeypair() throws {
        let pair = try XCTUnwrap(AuthKey.generate(), "the FFI should generate a keypair")

        XCTAssertTrue(pair.secretKey.hasPrefix("ed25519-sec:"))
        XCTAssertTrue(pair.publicKey.hasPrefix("ed25519-pub:"))
        // The public half is derived, never stored — so deriving it again must
        // give the same answer.
        XCTAssertEqual(AuthKey.publicKey(forSecret: pair.secretKey), pair.publicKey)
    }

    func testPublicKeyRejectsAnythingThatIsNotASecretKey() {
        XCTAssertNil(AuthKey.publicKey(forSecret: ""))
        XCTAssertNil(AuthKey.publicKey(forSecret: "not-a-key"))
        // A public key is not a secret key.
        let pair = AuthKey.generate()
        XCTAssertNil(AuthKey.publicKey(forSecret: pair?.publicKey ?? "ed25519-pub:x"))
    }

    func testAddPersistsAndReloadsWithDerivedPublicKeys() throws {
        // The fake's client closures hold it unowned, so keep it alive here.
        let storage = InMemoryAuthKeyKeychain()
        let client = storage.client
        let store = AuthKeyStore(client: client)
        let pair = try XCTUnwrap(AuthKey.generate())

        let added = try unwrapSuccess(store.add(name: "  this  mac  ", secret: " \(pair.secretKey) "))
        XCTAssertEqual(added.name, "this  mac")
        XCTAssertEqual(added.secret, pair.secretKey)
        XCTAssertEqual(added.publicKey, pair.publicKey)

        // A second store over the same storage sees the key, public half and
        // all (it is re-derived on load, not persisted).
        let reloaded = AuthKeyStore(client: client)
        XCTAssertEqual(reloaded.keys.count, 1)
        XCTAssertEqual(reloaded.keys.first?.id, added.id)
        XCTAssertEqual(reloaded.keys.first?.publicKey, pair.publicKey)
        XCTAssertEqual(reloaded.key(id: added.id)?.secret, pair.secretKey)
    }

    func testAddRejectsBadNamesAndSecrets() throws {
        let storage = InMemoryAuthKeyKeychain()
        let store = AuthKeyStore(client: storage.client)
        let pair = try XCTUnwrap(AuthKey.generate())
        let other = try XCTUnwrap(AuthKey.generate())

        XCTAssertNotNil(failure(store.add(name: "   ", secret: pair.secretKey)))
        XCTAssertNotNil(failure(store.add(name: "Laptop", secret: "not-a-secret")))
        _ = try unwrapSuccess(store.add(name: "Laptop", secret: pair.secretKey))
        // Same name (case-insensitively) and same keypair are both refused.
        XCTAssertNotNil(failure(store.add(name: "laptop", secret: other.secretKey)))
        XCTAssertNotNil(failure(store.add(name: "Phone", secret: pair.secretKey)))
        XCTAssertEqual(store.keys.count, 1)
    }

    func testRenameAndDelete() throws {
        let storage = InMemoryAuthKeyKeychain()
        let client = storage.client
        let store = AuthKeyStore(client: client)
        let first = try unwrapSuccess(
            store.add(name: "First", secret: try XCTUnwrap(AuthKey.generate()).secretKey))
        let second = try unwrapSuccess(
            store.add(name: "Second", secret: try XCTUnwrap(AuthKey.generate()).secretKey))

        XCTAssertNil(store.rename(id: first.id, to: "  Renamed  "))
        XCTAssertEqual(store.key(id: first.id)?.name, "Renamed")
        // A key can keep its own name; it cannot take another's.
        XCTAssertNil(store.rename(id: first.id, to: "Renamed"))
        XCTAssertNotNil(store.rename(id: first.id, to: "Second"))
        XCTAssertNotNil(store.rename(id: first.id, to: " "))
        XCTAssertEqual(store.key(id: first.id)?.name, "Renamed")

        XCTAssertNil(store.delete(id: second.id))
        XCTAssertEqual(store.keys.map(\.id), [first.id])
        XCTAssertEqual(AuthKeyStore(client: client).keys.map(\.id), [first.id])
    }

    private func unwrapSuccess(
        _ result: Result<AuthKeyStore.Key, AuthKeyStore.ValidationError>,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> AuthKeyStore.Key {
        switch result {
        case .success(let key):
            return key
        case .failure(let error):
            XCTFail("unexpected failure: \(error.message)", file: file, line: line)
            throw error
        }
    }

    private func failure(
        _ result: Result<AuthKeyStore.Key, AuthKeyStore.ValidationError>
    ) -> AuthKeyStore.ValidationError? {
        if case .failure(let error) = result { return error }
        return nil
    }
}
