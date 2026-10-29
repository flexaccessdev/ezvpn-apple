import XCTest
@testable import TunnelCore

final class KeychainModeTests: XCTestCase {
    func testUnsetIsTheSystemKeychain() {
        XCTAssertEqual(KeychainMode.parse(nil), .success(.system))
    }

    func testMockIsAskedForByNameOnly() {
        XCTAssertEqual(KeychainMode.parse("mock"), .success(.mock))
        // A typo is not the real Keychain.
        for wrong in ["", "Mock", "memory", "1"] {
            guard case .failure(let error) = KeychainMode.parse(wrong) else {
                return XCTFail("\(wrong.debugDescription) was accepted")
            }
            XCTAssertTrue(error.description.contains("the only value it takes"), error.description)
        }
    }
}
