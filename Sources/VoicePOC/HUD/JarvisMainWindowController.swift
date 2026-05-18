import AppKit
import SwiftUI

/// VoicePOC's main visible window. Hosts the JARVIS HUD orb on the left and
/// a live diagnostic status panel on the right. The whole window is a
/// SwiftUI hosted view — no Metal, just SwiftUI animations.
@MainActor
public final class JarvisMainWindowController: NSWindowController, NSWindowDelegate {
    public let state: JarvisHUDState

    public init(state: JarvisHUDState) {
        self.state = state

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let initialSize = NSSize(width: 920, height: 480)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePOC — JARVIS"
        window.minSize = NSSize(width: 800, height: 420)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()

        let content = HStack(spacing: 0) {
            JarvisHUDView(state: state)
                .frame(width: 380)
                .background(Color.black)
            Divider().background(Color(white: 0.18))
            JarvisStatusView(state: state)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.05))

        let host = NSHostingController(rootView: content)
        window.contentViewController = host

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) unsupported")
    }

    public override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Standalone window for the log stream. Opened from menu (View → Log
/// Stream… / ⌘L).
@MainActor
public final class LogStreamWindowController: NSWindowController, NSWindowDelegate {
    public init() {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 540),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "VoicePOC — Log Stream"
        window.minSize = NSSize(width: 600, height: 320)
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.center()

        let host = NSHostingController(rootView: LogStreamView())
        window.contentViewController = host

        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) unsupported")
    }
}
