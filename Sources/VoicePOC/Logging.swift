import Foundation
import Logging

/// Project-wide logging utilities.
///
/// Three channels:
///  - `voicepoc.state` — state transitions
///  - `voicepoc.audio` — RMS, frame counts, engine lifecycle
///  - `voicepoc.perf` — latency measurements
///
/// **Invariant:** transcript text is never logged. Callers MUST pass transcript strings
/// through `Logging.redact(_:)` before logging.
public enum Log {
    public static let state = Logger(label: "voicepoc.state")
    public static let audio = Logger(label: "voicepoc.audio")
    public static let perf  = Logger(label: "voicepoc.perf")

    /// Redact a sensitive string for logging. Returns a length-only descriptor.
    public static func redact(_ value: String) -> String {
        "redacted, len=\(value.count)"
    }
}
