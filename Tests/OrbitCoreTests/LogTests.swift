import Foundation
import Testing
@testable import OrbitCore

@Test func logAppendsTimestampedLine() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "orbit-log-\(UUID()).log")
    defer { try? FileManager.default.removeItem(at: url) }
    Log.configure(fileURL: url)
    Log.info("hello orbit")
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("[INFO] hello orbit"))
}
