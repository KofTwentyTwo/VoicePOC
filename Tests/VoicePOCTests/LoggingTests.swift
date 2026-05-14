import XCTest
@testable import VoicePOC

final class LoggingTests: XCTestCase {
    func testRedactReturnsLengthNotContent() {
        let result = Log.redact("the secret transcript text")
        XCTAssertEqual(result, "redacted, len=26")
    }

    func testRedactEmptyString() {
        XCTAssertEqual(Log.redact(""), "redacted, len=0")
    }
}
