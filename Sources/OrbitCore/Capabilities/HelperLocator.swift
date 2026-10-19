import AppKit
import Foundation

public struct HelperLocator {
    public static let ffmpegPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"]
    public static let bundleIDs: [Helper: [String]] = [
        .pages: ["com.apple.Pages", "com.apple.iWork.Pages"],
        .keynote: ["com.apple.Keynote", "com.apple.iWork.Keynote"],
        .numbers: ["com.apple.Numbers", "com.apple.iWork.Numbers"],
    ]

    private let isExecutable: (String) -> Bool
    private let appInstalled: (String) -> Bool

    public init(
        isExecutable: @escaping (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
        appInstalled: @escaping (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    ) {
        self.isExecutable = isExecutable
        self.appInstalled = appInstalled
    }

    public func locate(customFFmpegPath: String?) -> Capabilities {
        var candidates = Self.ffmpegPaths
        if let custom = customFFmpegPath, !custom.isEmpty { candidates.insert(custom, at: 0) }
        let ffmpeg = candidates.first(where: isExecutable).map { URL(fileURLWithPath: $0) }
        func id(_ h: Helper) -> String? { Self.bundleIDs[h]?.first(where: appInstalled) }
        return Capabilities(ffmpeg: ffmpeg, pagesBundleID: id(.pages), keynoteBundleID: id(.keynote), numbersBundleID: id(.numbers))
    }
}
