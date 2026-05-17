import Foundation
import AppKit

/// Global hotkey listener.
///
/// Uses `NSEvent.addGlobalMonitorForEvents(.keyDown)` so the hotkey works no
/// matter which app is focused. On macOS this requires the user to grant
/// **Input Monitoring** (and/or Accessibility) permission to the binary — the
/// system will prompt automatically on first use.
///
/// If the global monitor cannot be installed (no permission, sandboxed run,
/// etc.) the monitor logs a warning and does nothing; main.swift provides a
/// stdin-based fallback so the user can still drive the conversation.
public final class HotkeyMonitor: @unchecked Sendable {

    public let keyCode: UInt16
    private let onToggle: @Sendable () -> Void
    private var monitor: Any?
    private var localMonitor: Any?

    /// - Parameters:
    ///   - keyCode: macOS virtual key code. Default `122` = F1.
    ///   - onToggle: called on every press of the configured hotkey. Invoked on
    ///     the main thread (NSEvent monitor delivery thread). Hop to your own
    ///     executor if you need to.
    public init(keyCode: UInt16 = 122, onToggle: @escaping @Sendable () -> Void) {
        self.keyCode = keyCode
        self.onToggle = onToggle
    }

    /// Install the global + local NSEvent monitors. Idempotent.
    public func start() {
        guard monitor == nil else { return }

        let cb: (NSEvent) -> Void = { [keyCode = self.keyCode, onToggle = self.onToggle] event in
            if event.keyCode == keyCode {
                Log.state.info("hotkey: keyCode=\(keyCode) pressed")
                onToggle()
            }
        }

        let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: cb)
        if global == nil {
            Log.state.warning("HotkeyMonitor: failed to install global key monitor — grant Input Monitoring permission in System Settings → Privacy & Security. Falling back to stdin-only toggle.")
        } else {
            Log.state.info("HotkeyMonitor: global monitor installed (keyCode=\(keyCode))")
        }
        self.monitor = global

        // Local monitor catches presses when this process is the active app
        // (uncommon for a CLI, but harmless to install).
        self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            cb(event)
            return event
        }
    }

    /// Remove the installed monitors.
    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        Log.state.info("HotkeyMonitor: stopped")
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }
}
