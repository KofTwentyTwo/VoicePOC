import XCTest
@testable import VoicePOC

final class LoggingTests: XCTestCase {
    func testRedactReturnsLengthNotContent() {
        let result = Logging.redact("the secret transcript text")
        XCTAssertEqual(result, "redacted, len=26")
    }

    func testRedactEmptyString() {
        XCTAssertEqual(Logging.redact(""), "redacted, len=0")
    }
}
