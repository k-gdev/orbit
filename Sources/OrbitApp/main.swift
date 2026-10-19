import AppKit

// Hidden debug modes: each renders or runs headless and exits without showing UI.
MainActor.assumeIsolated {
    WheelSnapshot.runIfRequested(CommandLine.arguments)
    HUDSnapshot.runIfRequested(CommandLine.arguments)
    PerformCommand.runIfRequested(CommandLine.arguments)
    SettingsSnapshot.runIfRequested(CommandLine.arguments)
    GlyphSnapshot.runIfRequested(CommandLine.arguments)
    EditorSnapshot.runIfRequested(CommandLine.arguments)
    EditorCheck.runIfRequested(CommandLine.arguments)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// `--diagnose-trigger` runs the normal app and also logs every trigger input sample
// (button, modifiers, pointer, drag pasteboard) and drop callback to orbit.log.
let delegate = AppDelegate(diagnoseTrigger: CommandLine.arguments.contains("--diagnose-trigger"))
app.delegate = delegate
app.run()
