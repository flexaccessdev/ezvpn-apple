import XCTest
@testable import TunnelCore

final class TunnelNameValidationTests: XCTestCase {
    // MARK: - validateTunnelName

    func testTrimsAndAccepts() {
        XCTAssertEqual(validateTunnelName("  Home  ", existing: []), .success("Home"))
    }

    func testRejectsEmpty() {
        XCTAssertEqual(validateTunnelName("", existing: []), .failure(.empty))
        XCTAssertEqual(validateTunnelName("   \n", existing: []), .failure(.empty))
    }

    func testRejectsExactDuplicate() {
        XCTAssertEqual(validateTunnelName("Home", existing: ["Home"]), .failure(.duplicate))
    }

    func testRejectsCaseInsensitiveDuplicate() {
        XCTAssertEqual(validateTunnelName("home", existing: ["Home"]), .failure(.duplicate))
        XCTAssertEqual(validateTunnelName("WORK", existing: ["work"]), .failure(.duplicate))
    }

    func testAllowsSelfOnRename() {
        // Editing "Home" and keeping the same name (or a case variant) is fine.
        XCTAssertEqual(
            validateTunnelName("Home", existing: ["Home", "Work"], excluding: "Home"),
            .success("Home"))
        XCTAssertEqual(
            validateTunnelName("home", existing: ["Home", "Work"], excluding: "Home"),
            .success("home"))
    }

    func testRenameStillRejectsCollisionWithOther() {
        XCTAssertEqual(
            validateTunnelName("Work", existing: ["Home", "Work"], excluding: "Home"),
            .failure(.duplicate))
    }

    // MARK: - tunnelNameIsLessThan

    func testNumericOrdering() {
        XCTAssertTrue(tunnelNameIsLessThan("tunnel2", "tunnel10"))
        XCTAssertFalse(tunnelNameIsLessThan("tunnel10", "tunnel2"))
    }

    func testCaseInsensitiveOrdering() {
        XCTAssertTrue(tunnelNameIsLessThan("apple", "Banana"))
        XCTAssertFalse(tunnelNameIsLessThan("Banana", "apple"))
    }
}
