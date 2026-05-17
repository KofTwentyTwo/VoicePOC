import Cocoa

// Standard macOS app entry. NSApplication.run() drives the AppKit run loop
// on the main thread — required for NSEvent global-key monitors (the F1
// hotkey) to deliver, for AVSpeechSynthesizer delegate callbacks to fire,
// and for libdispatch to remain compatible with Swift 6 strict concurrency.
//
// We use .accessory activation policy → LSUIElement-style app: no Dock
// icon, no menu bar, but still a real NSApplication with a working run
// loop. Mirrors MetalPOC's pattern.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
