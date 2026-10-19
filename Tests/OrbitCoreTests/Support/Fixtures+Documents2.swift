import AppKit
import Foundation
import PDFKit
@testable import OrbitCore

/// Word-processing inputs and a reader that pulls the text back out of any document format Orbit writes.
extension Fixtures {
    /// A one-paragraph .docx (written with `NSAttributedString`'s Office Open XML writer).
    static func docx(_ text: String, in dir: URL, name: String = "doc.docx") -> URL {
        richDocument(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)]),
                     type: .officeOpenXML, name: name, in: dir)
    }

    /// `attributed` written in `type` (RTF, DOC, DOCX, HTML) to `dir/name`. Never overwrites.
    static func richDocument(_ attributed: NSAttributedString, type: NSAttributedString.DocumentType,
                             name: String, in dir: URL) -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        do {
            let data = try attributed.data(from: NSRange(location: 0, length: attributed.length),
                                           documentAttributes: [.documentType: type])
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            preconditionFailure("Fixtures.richDocument \(name): \(error)")
        }
        return url
    }

    /// An .rtfd package with `text` as its body.
    static func rtfd(_ text: String, name: String = "pack.rtfd", in dir: URL) -> URL {
        let attributed = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let url = dir.appending(path: name, directoryHint: .isDirectory)
        guard let wrapper = attributed.rtfdFileWrapper(from: NSRange(location: 0, length: attributed.length),
                                                       documentAttributes: [:]) else {
            preconditionFailure("Fixtures.rtfd: no wrapper")
        }
        do {
            try wrapper.write(to: url, options: [], originalContentsURL: nil)
        } catch {
            preconditionFailure("Fixtures.rtfd: \(error)")
        }
        return url
    }

    /// A plain text file `dir/name`.
    static func text(_ contents: String, _ name: String, in dir: URL) -> URL {
        file(name, contents, in: dir)
    }

    /// A Finder text clipping: a binary property list `{"UTI-Data": {"public.utf8-plain-text": text}}`.
    /// Real clippings may carry the text as `Data`; `asData` writes that variant.
    static func textClipping(_ text: String, in dir: URL, name: String = "Clip.textClipping", asData: Bool = false) -> URL {
        let value: Any = asData ? Data(text.utf8) : text
        let plist: [String: Any] = ["UTI-Data": ["public.utf8-plain-text": value]]
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            preconditionFailure("Fixtures.textClipping: \(error)")
        }
        return url
    }

    /// The text of a pdf, docx, txt, md, html or epub file.
    static func textOf(_ url: URL) async throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf":
            return PDFDocument(url: url)?.string ?? ""
        case "docx":
            return try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil).string
        case "html":
            return try await MainActor.run {
                try NSAttributedString(url: url, options: [.documentType: NSAttributedString.DocumentType.html,
                                                           .characterEncoding: String.Encoding.utf8.rawValue],
                                       documentAttributes: nil).string
            }
        case "epub":
            var all = ""
            for entry in try await unzipList(url) where entry.hasPrefix("OEBPS/chapter-") && entry.hasSuffix(".xhtml") {
                all += try await unzipRead(url, entry)
            }
            return all.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        default:
            return try String(contentsOf: url, encoding: .utf8)
        }
    }
}
