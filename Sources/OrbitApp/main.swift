import AppKit

// Hidden debug mode: renders the wheel to a PNG and exits without showing UI.
MainActor.assumeIsolated { WheelSnapshot.runIfRequested(CommandLine.arguments) }

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
