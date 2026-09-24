import XCTest
@testable import TunnelCore

final class ExtensionVersionTests: XCTestCase {
    private let app = BundleVersion(short: "0.0.7", build: "7")

    func testMatchingReply() {
        XCTAssertEqual(checkRunningExtension(expected: app, reply: app.jsonData), .match)
    }

    func testOlderRunningExtension() {
        let old = BundleVersion(short: "0.0.6", build: "6")
        XCTAssertEqual(
            checkRunningExtension(expected: app, reply: old.jsonData),
            .mismatch(running: old))
    }

    func testSameMarketingDifferentBuildIsMismatch() {
        // Dev iteration bumps only the build; sysextd treats it as a new version.
        let rebuilt = BundleVersion(short: "0.0.7", build: "6")
        XCTAssertEqual(
            checkRunningExtension(expected: app, reply: rebuilt.jsonData),
            .mismatch(running: rebuilt))
    }

    func testNoReplyMeansPreQueryExtension() {
        XCTAssertEqual(checkRunningExtension(expected: app, reply: nil), .mismatch(running: nil))
    }

    func testMalformedReplyMeansUnknown() {
        XCTAssertEqual(
            checkRunningExtension(expected: app, reply: Data("{\"mtu\":1280}".utf8)),
            .mismatch(running: nil))
    }

    func testInfoDictionary() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.0.7", "CFBundleVersion": "7"]
        XCTAssertEqual(BundleVersion(infoDictionary: info), app)
        XCTAssertNil(BundleVersion(infoDictionary: ["CFBundleVersion": "7"]))
        XCTAssertNil(BundleVersion(infoDictionary: nil))
        XCTAssertEqual(app.description, "0.0.7 (7)")
    }
}
