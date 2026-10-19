import Foundation
@testable import OrbitCore

/// Slide decks and spreadsheets for the Office processor tests.
extension Fixtures {
    /// A .pptx with `slides` one-colour slides, written by `PPTXWriter`. Never overwrites.
    static func pptxDeck(slides: Int, name: String = "a.pptx", in dir: URL) async throws -> URL {
        let images = (1...slides).map { image("slide-src-\($0).png", w: 16, h: 9, in: dir) }
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try await PPTXWriter.write(slideImages: images, slideSize: CGSize(width: 960, height: 540), to: url)
        return url
    }

    /// A one-sheet .xlsx written by `XLSXWriter`. Never overwrites.
    static func xlsxFile(_ rows: [[String]], name: String = "s.xlsx", in dir: URL) async throws -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try await XLSXWriter.write(rows: rows, sheetName: "Sheet1", to: url)
        return url
    }

    /// A one-sheet .ods written by `ODSWriter`. Never overwrites.
    static func odsFile(_ rows: [[String]], name: String = "s.ods", in dir: URL) async throws -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        try await ODSWriter.write(rows: rows, sheetName: "Sheet1", to: url)
        return url
    }

    /// `contents` encoded as `encoding` (with an optional BOM first), written to `dir/name`. Never overwrites.
    static func encodedText(_ contents: String, _ name: String, encoding: String.Encoding, bom: [UInt8] = [], in dir: URL) -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        do {
            try (Data(bom) + (contents.data(using: encoding) ?? Data())).write(to: url, options: .withoutOverwriting)
        } catch {
            preconditionFailure("Fixtures.encodedText \(name): \(error)")
        }
        return url
    }
}
