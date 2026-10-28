import AppKit
import ApplicationServices
import OrbitCore

/// One window of a running app, read through Accessibility.
struct AXWindow {
    let element: AXUIElement
    let pid: pid_t
    let title: String?
    /// Global coordinates, origin at the primary display's top left (as Accessibility reports).
    let frame: CGRect
    let isMinimised: Bool
    let subrole: String?
    /// The window server's number, through the private `_AXUIElementGetWindow` (nil when it is missing).
    let number: CGWindowID?
    /// Unique within one read of the app's windows.
    let id: String

    var descriptor: WindowDescriptor { WindowDescriptor(number: number.map(Int.init), title: title, frame: frame) }
    var summary: WindowSummary { WindowSummary(title: title, size: frame.size, isMinimised: isMinimised, subrole: subrole) }
}

/// Reads apps' windows and acts on them through Accessibility: list, bring forward (`kAXRaiseAction` plus
/// activating the app), minimise and restore (`kAXMinimizedAttribute`), close (pressing the close button).
/// Without the Accessibility permission every read returns nothing and every action does nothing. Each
/// element gets a short messaging timeout so a hung app can't stall the caller. Reads are safe off the main
/// thread (the Windows tab and the Dock preview read on a background queue).
enum AXWindowService {
    static let messagingTimeout: Float = 0.25

    /// `_AXUIElementGetWindow(element, &windowID)`: private, but stable since 10.x; loaded via `PrivateSymbol`.
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let hiServices = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    private static let getWindow = PrivateSymbol.load("_AXUIElementGetWindow", from: hiServices, as: GetWindow.self)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The app's windows as Accessibility lists them (front to back), unfiltered.
    static func windows(of pid: pid_t) -> [AXWindow] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let elements: [AXUIElement] = AX.copy(app, kAXWindowsAttribute) else { return [] }
        return elements.enumerated().compactMap { index, element in
            AXUIElementSetMessagingTimeout(element, messagingTimeout)
            guard let origin = AX.point(element, kAXPositionAttribute), let size = AX.size(element, kAXSizeAttribute) else { return nil }
            let number = windowNumber(element)
            return AXWindow(element: element, pid: pid,
                            title: AX.copy(element, kAXTitleAttribute),
                            frame: CGRect(origin: origin, size: size),
                            isMinimised: AX.copy(element, kAXMinimizedAttribute) ?? false,
                            subrole: AX.copy(element, kAXSubroleAttribute),
                            number: number,
                            id: number.map { "w\($0)" } ?? "p\(pid)-\(index)")
        }
    }

    /// The windows the Dock preview and the Windows tab show, in display order (see `WindowListing`).
    static func listedWindows(of pid: pid_t, showMinimised: Bool) -> [AXWindow] {
        let all = windows(of: pid)
        return WindowListing.visibleIndices(all.map(\.summary), showMinimised: showMinimised).map { all[$0] }
    }

    /// Brings the window in front of the app's others and activates the app (unhiding and restoring as needed).
    @MainActor
    static func bringForward(_ window: AXWindow) {
        guard AXIsProcessTrusted() else { return }
        let running = NSRunningApplication(processIdentifier: window.pid)
        if running?.isHidden == true { running?.unhide() }
        if window.isMinimised {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        running?.activate(options: [])
    }

    /// Minimises (true) or restores (false) the window.
    static func setMinimised(_ window: AXWindow, _ minimised: Bool) {
        guard AXIsProcessTrusted() else { return }
        AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, minimised ? kCFBooleanTrue : kCFBooleanFalse)
    }

    /// Presses the window's close button (the app may still ask to save). False when it has none.
    @discardableResult
    static func close(_ window: AXWindow) -> Bool {
        guard AXIsProcessTrusted(), let button: AXUIElement = AX.copy(window.element, kAXCloseButtonAttribute) else { return false }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
    }

    private static func windowNumber(_ element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var number: CGWindowID = 0
        return getWindow(element, &number) == .success && number != 0 ? number : nil
    }
}

/// Small typed readers over `AXUIElementCopyAttributeValue`.
enum AX {
    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
        return value as? T
    }

    static func point(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
        guard let value = axValue(element, attribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ element: AXUIElement, _ attribute: String) -> CGSize? {
        guard let value = axValue(element, attribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
