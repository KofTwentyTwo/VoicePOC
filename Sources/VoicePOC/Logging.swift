import Foundation
import Logging

/// Project-wide swift-log loggers. **Most new code should use `LogStream`**
/// (the in-app ring buffer) instead — it mirrors to stdout AND a tail-able
/// file AND the in-app log window. `Log` is preserved for tests and for
/// existing call sites that were already using swift-log.
public enum Log {
    public static let state = Logger(label: "voicepoc.state")
    public static let audio = Logger(label: "voicepoc.audio")
    public static let perf  = Logger(label: "voicepoc.perf")

    /// Return a length-only descriptor of `value`. Use only when the actual
    /// content is sensitive.
    public static func redact(_ value: String) -> String {
        "redacted, len=\(value.count)"
    }
}
