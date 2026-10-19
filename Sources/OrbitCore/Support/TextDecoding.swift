import Foundation

/// Turns the bytes of a text file into a string without assuming UTF-8. One decoder for documents,
/// subtitles and delimited text.
enum TextDecoding {
    /// UTF-8 (strictly; a BOM is dropped), UTF-16/32 by byte-order mark, then Windows-1252, then
    /// Latin-1 (which accepts any bytes).
    static func string(from data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf32) { return s }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }
}
