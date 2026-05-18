import Foundation
import os

/// In-memory ring buffer of recent system events from every subsystem, plus
/// a single sink that mirrors entries to stdout AND a file at /tmp/voicepoc.log
/// for `tail -f`. The log viewer window polls `snapshot()` to render entries.
///
/// Pattern lifted verbatim from VisionPOC's `LogStream` so the VoicePOC
/// debugging experience matches VisionPOC's familiar shape.
public final class LogStream: @unchecked Sendable {
    public static let shared = LogStream()

    public enum Level: String, Sendable, CaseIterable, Identifiable {
        case debug = "DBG"
        case info  = "INF"
        case warn  = "WRN"
        case error = "ERR"
        public var id: String { rawValue }
    }

    public enum Source: String, Sendable, CaseIterable, Identifiable {
        case app    = "APP"
        case audio  = "AUDIO"
        case wake   = "WAKE"
        case stt    = "STT"
        case vad    = "VAD"
        case llm    = "LLM"
        case tts    = "TTS"
        case hud    = "HUD"
        case state  = "STATE"
        case perf   = "PERF"
        public var id: String { rawValue }
    }

    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let level: Level
        public let source: Source
        public let message: String
    }

    private var lock = os_unfair_lock_s()
    private var buffer: [Entry] = []
    private let maxEntries: Int = 2000

    /// Monotonic counter bumped on every append. The viewer reads this to
    /// short-circuit polling when nothing has changed.
    private var _version: UInt64 = 0
    public var version: UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return _version
    }

    /// File handle for the tail-able log mirror at `/tmp/voicepoc.log`.
    /// Created once at bootstrap; appended to on every log call.
    /// `nonisolated(unsafe)` because writes are gated by `lock` below.
    private nonisolated(unsafe) static var fileHandle: FileHandle?

    /// Truncate the on-disk log so each session starts with a fresh file.
    /// Call once at app start before any `.shared.log(...)`.
    public static func bootstrapFile(path: String = "/tmp/voicepoc.log") {
        FileManager.default.createFile(atPath: path, contents: nil)
        Self.fileHandle = FileHandle(forWritingAtPath: path)
    }

    public func log(_ message: String, level: Level = .info, source: Source = .app) {
        let entry = Entry(timestamp: Date(), level: level, source: source, message: message)
        os_unfair_lock_lock(&lock)
        buffer.append(entry)
        if buffer.count > maxEntries {
            buffer.removeFirst(buffer.count - maxEntries)
        }
        _version &+= 1
        os_unfair_lock_unlock(&lock)

        // Mirror to stdout for tail-from-terminal scenarios.
        let stamp = LogStream.timeFormatter.string(from: entry.timestamp)
        let line = "[\(stamp)] \(level.rawValue) \(source.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)) \(message)"
        print(line)

        // Mirror to /tmp/voicepoc.log so `tail -f /tmp/voicepoc.log` works
        // even when the app is launched from Finder (no terminal stdout).
        if let h = LogStream.fileHandle, let data = (line + "\n").data(using: .utf8) {
            try? h.write(contentsOf: data)
        }
    }

    public func snapshot() -> [Entry] {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return buffer
    }

    public func clear() {
        os_unfair_lock_lock(&lock)
        buffer.removeAll()
        _version &+= 1
        os_unfair_lock_unlock(&lock)
    }

    private static let timeFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()
}
