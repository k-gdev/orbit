import Foundation

public enum Helper: String, CaseIterable, Sendable {
    case ffmpeg, pages, keynote, numbers

    public var displayName: String {
        switch self {
        case .ffmpeg: "ffmpeg"
        case .pages: "Pages"
        case .keynote: "Keynote"
        case .numbers: "Numbers"
        }
    }

    public var installHint: String {
        switch self {
        case .ffmpeg: "brew install ffmpeg"
        case .pages, .keynote, .numbers: "Free on the Mac App Store"
        }
    }
}

public struct Capabilities: Sendable, Equatable {
    public var ffmpeg: URL?
    public var pagesBundleID: String?
    public var keynoteBundleID: String?
    public var numbersBundleID: String?

    public init(ffmpeg: URL? = nil, pagesBundleID: String? = nil, keynoteBundleID: String? = nil, numbersBundleID: String? = nil) {
        self.ffmpeg = ffmpeg
        self.pagesBundleID = pagesBundleID
        self.keynoteBundleID = keynoteBundleID
        self.numbersBundleID = numbersBundleID
    }

    public func has(_ helper: Helper) -> Bool {
        switch helper {
        case .ffmpeg: ffmpeg != nil
        default: bundleID(for: helper) != nil
        }
    }

    public func bundleID(for helper: Helper) -> String? {
        switch helper {
        case .ffmpeg: nil
        case .pages: pagesBundleID
        case .keynote: keynoteBundleID
        case .numbers: numbersBundleID
        }
    }

    public static let none = Capabilities()

    public static let everything = Capabilities(
        ffmpeg: URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
        pagesBundleID: "com.apple.Pages",
        keynoteBundleID: "com.apple.Keynote",
        numbersBundleID: "com.apple.Numbers")
}
