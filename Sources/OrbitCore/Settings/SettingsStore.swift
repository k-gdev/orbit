import Combine
import Foundation

public final class SettingsStore: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let isEnabled = "isEnabled"
        static let revealInFinder = "revealInFinder"
        static let jpegQuality = "jpegQuality"
        static let heicQuality = "heicQuality"
        static let webpQuality = "webpQuality"
        static let avifQuality = "avifQuality"
        static let pdfDPI = "pdfDPI"
        static let imageFitPresets = "imageFitPresets"
        static let videoFitPresets = "videoFitPresets"
        static let pdfFitPresets = "pdfFitPresets"
        static let favouriteFolders = "favouriteFolders"
        static let terminalBundleID = "terminalBundleID"
        static let customFFmpegPath = "customFFmpegPath"
        static let hapticsEnabled = "hapticsEnabled"
    }

    @Published public var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Key.isEnabled) } }
    @Published public var revealInFinder: Bool { didSet { defaults.set(revealInFinder, forKey: Key.revealInFinder) } }
    @Published public var jpegQuality: Double { didSet { defaults.set(jpegQuality, forKey: Key.jpegQuality) } }
    @Published public var heicQuality: Double { didSet { defaults.set(heicQuality, forKey: Key.heicQuality) } }
    @Published public var webpQuality: Double { didSet { defaults.set(webpQuality, forKey: Key.webpQuality) } }
    @Published public var avifQuality: Double { didSet { defaults.set(avifQuality, forKey: Key.avifQuality) } }
    @Published public var pdfDPI: Int { didSet { defaults.set(pdfDPI, forKey: Key.pdfDPI) } }
    @Published public var imageFitPresets: [Int64] { didSet { defaults.set(imageFitPresets.map { NSNumber(value: $0) }, forKey: Key.imageFitPresets) } }
    @Published public var videoFitPresets: [Int64] { didSet { defaults.set(videoFitPresets.map { NSNumber(value: $0) }, forKey: Key.videoFitPresets) } }
    @Published public var pdfFitPresets: [Int64] { didSet { defaults.set(pdfFitPresets.map { NSNumber(value: $0) }, forKey: Key.pdfFitPresets) } }
    @Published public var favouriteFolders: [URL] { didSet { defaults.set(favouriteFolders.map(\.path), forKey: Key.favouriteFolders) } }
    @Published public var terminalBundleID: String { didSet { defaults.set(terminalBundleID, forKey: Key.terminalBundleID) } }
    @Published public var customFFmpegPath: String? {
        didSet {
            if let p = customFFmpegPath { defaults.set(p, forKey: Key.customFFmpegPath) }
            else { defaults.removeObject(forKey: Key.customFFmpegPath) }
        }
    }
    @Published public var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) as? Bool ?? d }
        func double(_ k: String, _ d: Double) -> Double { defaults.object(forKey: k) as? Double ?? d }
        func int64s(_ k: String, _ d: [Int64]) -> [Int64] {
            (defaults.array(forKey: k) as? [NSNumber])?.map(\.int64Value) ?? d
        }
        isEnabled = bool(Key.isEnabled, true)
        revealInFinder = bool(Key.revealInFinder, true)
        jpegQuality = double(Key.jpegQuality, 0.85)
        heicQuality = double(Key.heicQuality, 0.8)
        webpQuality = double(Key.webpQuality, 0.8)
        avifQuality = double(Key.avifQuality, 0.7)
        pdfDPI = defaults.object(forKey: Key.pdfDPI) as? Int ?? 300
        imageFitPresets = int64s(Key.imageFitPresets, [500_000, 1_000_000, 5_000_000])
        videoFitPresets = int64s(Key.videoFitPresets, [10_000_000, 25_000_000, 50_000_000, 100_000_000])
        pdfFitPresets = int64s(Key.pdfFitPresets, [1_000_000, 5_000_000, 10_000_000])
        if let paths = defaults.stringArray(forKey: Key.favouriteFolders) {
            favouriteFolders = paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            let fm = FileManager.default
            favouriteFolders = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
                .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        }
        terminalBundleID = defaults.string(forKey: Key.terminalBundleID) ?? "com.apple.Terminal"
        customFFmpegPath = defaults.string(forKey: Key.customFFmpegPath)
        hapticsEnabled = bool(Key.hapticsEnabled, true)
    }
}
