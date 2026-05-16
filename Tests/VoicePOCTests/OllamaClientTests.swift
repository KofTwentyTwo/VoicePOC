import XCTest
@testable import VoicePOC

final class OllamaClientTests: XCTestCase {
    /// Most tests are integration tests requiring Ollama running locally.
    /// Skip-by-default; enable with `OLLAMA_REAL=1`.
    private var liveAllowed: Bool {
        ProcessInfo.processInfo.environment["OLLAMA_REAL"] == "1"
    }

    func testHealthCheckSucceedsAgainstRunningOllama() async throws {
        try XCTSkipUnless(liveAllowed, "set OLLAMA_REAL=1 to enable")
        let client = OllamaClient()
        let ok = try await client.healthCheck()
        XCTAssertTrue(ok, "healthCheck should return true when Ollama is up + has the default model")
    }

    func testChatReturnsResponse() async throws {
        try XCTSkipUnless(liveAllowed, "set OLLAMA_REAL=1 to enable")
        let client = OllamaClient()
        let messages = [
            OllamaClient.Message(role: "system", content: "Reply in exactly two words."),
            OllamaClient.Message(role: "user", content: "Say hello back to me."),
        ]
        let response = try await client.chat(messages: messages)
        print("[ollama] response: '\(response)'")
        XCTAssertFalse(response.isEmpty, "expected non-empty response")
    }

    func testChatStreamYieldsTokens() async throws {
        try XCTSkipUnless(liveAllowed, "set OLLAMA_REAL=1 to enable")
        let client = OllamaClient()
        let messages = [
            OllamaClient.Message(role: "user", content: "Count from one to three."),
        ]
        var tokenCount = 0
        var fullText = ""
        for try await chunk in client.chatStream(messages: messages) {
            tokenCount += 1
            fullText += chunk
        }
        print("[ollama] stream: \(tokenCount) tokens, full text: '\(fullText)'")
        XCTAssertGreaterThan(tokenCount, 1, "should yield more than one streaming chunk")
        XCTAssertFalse(fullText.isEmpty)
    }

    func testHealthCheckFailsAgainstWrongPort() async throws {
        let badClient = OllamaClient(baseURL: URL(string: "http://localhost:9999")!)
        // Should not throw — should return false (unreachable).
        do {
            let ok = try await badClient.healthCheck()
            XCTAssertFalse(ok)
        } catch {
            // Throwing is also acceptable. Just don't crash.
        }
    }
}
