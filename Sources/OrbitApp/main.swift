import AppKit

// Hidden debug modes: each renders or runs headless and exits without showing UI.
MainActor.assumeIsolated {
    WheelSnapshot.runIfRequested(CommandLine.arguments)
    HUDSnapshot.runIfRequested(CommandLine.arguments)
    PerformCommand.runIfRequested(CommandLine.arguments)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
