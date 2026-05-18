import Cocoa

// Regular Dock app (not LSUIElement). User gets a real window + Dock icon
// + ⌘-tab presence. Mirrors VisionPOC's launch shape.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
