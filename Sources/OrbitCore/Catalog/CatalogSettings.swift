import Foundation

public struct CatalogSettings: Sendable {
    public var favouriteFolders: [URL]
    public var imageFitPresets: [Int64]
    public var videoFitPresets: [Int64]
    public var pdfFitPresets: [Int64]

    public init(favouriteFolders: [URL] = [],
                imageFitPresets: [Int64] = [500_000, 1_000_000, 5_000_000],
                videoFitPresets: [Int64] = [10_000_000, 25_000_000, 50_000_000, 100_000_000],
                pdfFitPresets: [Int64] = [1_000_000, 5_000_000, 10_000_000]) {
        self.favouriteFolders = favouriteFolders
        self.imageFitPresets = imageFitPresets
        self.videoFitPresets = videoFitPresets
        self.pdfFitPresets = pdfFitPresets
    }
}

extension SettingsStore {
    public var catalogSettings: CatalogSettings {
        CatalogSettings(favouriteFolders: favouriteFolders,
                        imageFitPresets: imageFitPresets,
                        videoFitPresets: videoFitPresets,
                        pdfFitPresets: pdfFitPresets)
    }
}
