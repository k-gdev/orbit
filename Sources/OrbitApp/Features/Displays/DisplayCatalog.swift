import AppKit
import IOKit
import CoreGraphics
import OrbitCore

/// One connected display, as the Displays tab sees it.
struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    /// `DisplayIdentity.key(for:)`: what per-display settings are stored under.
    let key: String
    /// The tile title ("P27u-20 · Left").
    let title: String
    let isBuiltIn: Bool
    let isAsleep: Bool
    /// The EDID facts DDC matching uses.
    let descriptor: DisplayDescriptor
    let modes: DisplayModeList
}

/// The displays macOS is drawing on (`NSScreen.screens`, so a hardware-mirrored secondary isn't listed
/// twice), in tile order and with titles that tell identical monitors apart. Cheap: no DDC, no IORegistry
/// walk; CoreDisplay's info dictionary (for `IODisplayLocation`) is read through `PrivateSymbol`.
@MainActor
enum DisplayCatalog {
    static func scan() -> [DisplayInfo] {
        let screens = NSScreen.screens.compactMap { screen in DisplayIdentity.displayID(for: screen).map { (screen, $0) } }
        let items = screens.map { screen, id in
            DisplayArrangement.Item(name: screen.localizedName, frame: CGDisplayBounds(id), isBuiltIn: CGDisplayIsBuiltin(id) != 0)
        }
        let titles = DisplayArrangement.titles(items, builtInName: macModelName)
        return DisplayArrangement.order(items).map { index in
            let id = screens[index].1
            return DisplayInfo(id: id, key: DisplayIdentity.key(for: id), title: titles[index], isBuiltIn: items[index].isBuiltIn,
                               isAsleep: CGDisplayIsAsleep(id) != 0, descriptor: descriptor(for: id),
                               modes: DisplayModeService.list(for: id))
        }
    }

    static func descriptor(for id: CGDirectDisplayID) -> DisplayDescriptor {
        DisplayDescriptor(vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id),
                          isBuiltIn: CGDisplayIsBuiltin(id) != 0, info: coreDisplayInfo(id))
    }

    /// "MacBook Pro", from the device tree's `product-name` ("MacBook Pro (16-inch, M5 Max)"); nil on Macs
    /// without it (Intel), where the built-in tile keeps the panel's name.
    static let macModelName: String? = {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return DisplayArrangement.macModelName(fromProductName: text)
    }()

    private typealias CreateInfo = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    private static func coreDisplayInfo(_ id: CGDirectDisplayID) -> [String: Any]? {
        guard let create = PrivateSymbol.load("CoreDisplay_DisplayCreateInfoDictionary",
                                              from: "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
                                              as: CreateInfo.self) else { return nil }
        return create(id)?.takeRetainedValue() as? [String: Any]
    }
}
