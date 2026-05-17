import AppKit
import SwiftUI

/// Hosts `JarvisHUDView` in a borderless, always-on-top, transparent window
/// positioned in the bottom-right of the main screen. Mirrors the windowing
/// pattern from MetalPOC's HUDWindowController, simplified for SwiftUI.
@MainActor
public final class JarvisHUDWindowController {
    public let state: JarvisHUDState
    private var window: NSWindow?

    public init(state: JarvisHUDState) {
        self.state = state
    }

    public func show() {
        if window != nil {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = JarvisHUDView(state: state)
        let hostingController = NSHostingController(rootView: contentView)
        hostingController.view.frame = NSRect(x: 0, y: 0, width: 360, height: 320)
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 320),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = hostingController
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar                  // always on top, above normal windows
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        window.isMovableByWindowBackground = true
        window.ignoresMouseEvents = false           // user can grab the HUD to move it

        // Position bottom-right of the primary screen with some padding.
        if let screen = NSScreen.main {
            let pad: CGFloat = 24
            let frame = screen.visibleFrame
            let x = frame.maxX - 360 - pad
            let y = frame.minY + pad
            window.setFrameOrigin(NSPoint(x: x, y: y))
        }

        window.orderFrontRegardless()
        self.window = window
    }

    public func hide() {
        window?.orderOut(nil)
    }
}
