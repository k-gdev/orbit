import Foundation
@testable import OrbitCore

/// Shared test inputs. Later processor tasks append their own generators here.
enum Fixtures {
    /// A new, empty directory under the system temp folder. The caller removes it.
    static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "orbit-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        } catch {
            preconditionFailure("Fixtures.tempDir: \(error)")
        }
        return dir
    }

    /// Writes `contents` to `dir/name` (intermediate folders are created). Never overwrites.
    static func file(_ name: String, _ contents: String, in dir: URL) -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            preconditionFailure("Fixtures.file \(name): \(error)")
        }
        return url
    }

    /// Homebrew's ffmpeg, when it is installed and executable.
    static let ffmpeg: URL? = {
        let path = "/opt/homebrew/bin/ffmpeg"
        return FileManager.default.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
    }()

    static var hasFFmpeg: Bool { ffmpeg != nil }

    /// The helpers really installed on this Mac.
    static let caps: Capabilities = HelperLocator().locate(customFFmpegPath: nil)
}
