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
/// Without the Accessibility permission every read returns nothing and every action does nothing.
///
/// Every element Orbit messages comes from `AX.application`, `AX.element` or `AX.elements`, which give it
/// the short `AX.timeout` (a timeout set on one element doesn't carry over to elements copied from it).
/// Reads run on a background queue (the Windows tab, the Dock preview); actions run on `actionQueue`, so an
/// app that answers with a modal alert, or not at all, never stalls Orbit's main thread.
enum AXWindowService {
    /// Raise, minimise and close are sent from here, never from the main thread.
    static let actionQueue = DispatchQueue(label: "com.orbit.windows.actions", qos: .userInitiated)

    /// `_AXUIElementGetWindow(element, &windowID)`: private, but stable since 10.x; loaded via `PrivateSymbol`.
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let hiServices = "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    private static let getWindow = PrivateSymbol.load("_AXUIElementGetWindow", from: hiServices, as: GetWindow.self)

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// The app's windows as Accessibility lists them (front to back), unfiltered. Accessibility only sees
    /// windows on the current Space plus minimised ones. Call off the main thread.
    static func windows(of pid: pid_t) -> [AXWindow] {
        guard AXIsProcessTrusted() else { return [] }
        let app = AX.application(pid)
        return AX.elements(app, kAXWindowsAttribute).enumerated().compactMap { index, element in
            guard let origin = AX.point(element, kAXPositionAttribute), let size = AX.size(element, kAXSizeAttribute) else { return nil }
            let number = windowNumber(element)
            return AXWindow(element: element, pid: pid,
                            title: AX.value(element, kAXTitleAttribute),
                            frame: CGRect(origin: origin, size: size),
                            isMinimised: AX.value(element, kAXMinimizedAttribute) ?? false,
                            subrole: AX.value(element, kAXSubroleAttribute),
                            number: number,
                            id: number.map { "w\($0)" } ?? "p\(pid)-\(index)")
        }
    }

    /// The windows the Windows tab shows, in display order (see `WindowListing`). Call off the main thread.
    static func listedWindows(of pid: pid_t, showMinimised: Bool) -> [AXWindow] {
        let all = windows(of: pid)
        return WindowListing.visibleIndices(all.map(\.summary), showMinimised: showMinimised).map { all[$0] }
    }

    /// Brings the window in front of the app's others and activates the app (unhiding and restoring as
    /// needed): cooperative activation first (`AppActivation`), then the window is raised on `actionQueue`,
    /// and raised again once the activation has landed (activating can bring another of its windows forward).
    @MainActor
    static func bringForward(_ window: AXWindow) {
        guard AXIsProcessTrusted() else { return }
        if let running = NSRunningApplication(processIdentifier: window.pid) { AppActivation.activate(running) }
        actionQueue.async { raise(window) }
        actionQueue.asyncAfter(deadline: .now() + 0.25) { raise(window) }
    }

    /// Minimises (true) or restores (false) the window, on `actionQueue`.
    static func setMinimised(_ window: AXWindow, _ minimised: Bool) {
        guard AXIsProcessTrusted() else { return }
        actionQueue.async {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, minimised ? kCFBooleanTrue : kCFBooleanFalse)
        }
    }

    /// Presses the window's close button on `actionQueue` (the app may still ask to save; a window without a
    /// close button is left alone).
    static func close(_ window: AXWindow) {
        guard AXIsProcessTrusted() else { return }
        actionQueue.async {
            guard let button = AX.element(window.element, kAXCloseButtonAttribute) else { return }
            AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
    }

    /// Restores, raises and makes main the window, and makes its app frontmost. Runs on `actionQueue`.
    static func raise(_ window: AXWindow) {
        if window.isMinimised {
            AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(AX.application(window.pid), kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    }

    private static func windowNumber(_ element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var number: CGWindowID = 0
        return getWindow(element, &number) == .success && number != 0 ? number : nil
    }
}

/// Typed access to Accessibility attributes. Elements are only obtained through `application`, `element`
/// and `elements`, which set `timeout` on each one: Accessibility's default is about 6 s per message, and a
/// timeout set on one element does not apply to the elements copied from it.
enum AX {
    /// How long Orbit waits for an app to answer one Accessibility message.
    static let timeout: Float = 0.25

    /// The app's Accessibility element, with `timeout`.
    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// An element-valued attribute (a close button, a list), with `timeout` set on the copy.
    static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let copied = value as! AXUIElement
        AXUIElementSetMessagingTimeout(copied, timeout)
        return copied
    }

    /// An array-of-elements attribute (windows, children, selected children), with `timeout` set on each.
    static func elements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let array = value as? [AnyObject] else { return [] }
        return array.compactMap { item in
            guard CFGetTypeID(item) == AXUIElementGetTypeID() else { return nil }
            let copied = item as! AXUIElement
            AXUIElementSetMessagingTimeout(copied, timeout)
            return copied
        }
    }

    /// A plain value (string, number, bool, URL). Never use it for elements; see `element` / `elements`.
    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
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
