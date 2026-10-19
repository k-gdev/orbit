import Foundation

/// What to ask Pages, Keynote or Numbers to produce.
public enum IWorkFormat: Sendable {
    case pdf, word, pages, powerpoint, keynote
    /// One image per slide, written into a folder. Only `.png` and `.jpg` are meaningful; anything else is PNG.
    case slideImages(OutputFormat)
    case excel, csv, numbers
}

/// Drives Pages, Keynote and Numbers through AppleScript to open a file and export or save it.
///
/// Paths reach the script only through `on run argv`; the one value interpolated into the script
/// text is the app's bundle ID, which comes from `Capabilities` and is never user data.
public struct IWorkBridge: Sendable {
    public let capabilities: Capabilities

    public init(capabilities: Capabilities) {
        self.capabilities = capabilities
    }

    /// The AppleScript for one export. `argv` is `{input path, output path}`.
    public static func script(app: Helper, bundleID: String, format: IWorkFormat) -> String {
        let command: String
        switch format {
        case .pdf: command = "export theDoc to outFile as PDF"
        case .word: command = "export theDoc to outFile as Microsoft Word"
        case .powerpoint: command = "export theDoc to outFile as Microsoft PowerPoint"
        case .excel: command = "export theDoc to outFile as Microsoft Excel"
        case .csv: command = "export theDoc to outFile as CSV"
        case .slideImages(let image):
            let name = image == .jpg ? "JPEG" : "PNG"
            command = "export theDoc to outFile as slide images with properties {image format:\(name)}"
        case .pages, .keynote, .numbers: command = "save theDoc in outFile"
        }
        return """
        on run argv
        	set inFile to POSIX file (item 1 of argv)
        	set outFile to POSIX file (item 2 of argv)
        	tell application id "\(bundleID)"
        		set theDoc to open inFile
        		try
        			\(command)
        		on error errMsg number errNum
        			close theDoc saving no
        			error errMsg number errNum
        		end try
        		close theDoc saving no
        	end tell
        end run
        """
    }

    /// Opens `input` in `app`, writes `format` to `to`, and closes the document without saving it.
    /// Throws `.helperMissing(app)` when the app is not installed, and refuses to overwrite `to`.
    public func export(_ input: URL, app: Helper, format: IWorkFormat, to: URL) async throws {
        guard let bundleID = capabilities.bundleID(for: app) else { throw OrbitError.helperMissing(app) }
        guard !FileManager.default.fileExists(atPath: to.path) else {
            throw OrbitError.unsupported("Refusing to overwrite existing file \(to.lastPathComponent).")
        }
        let script = Self.script(app: app, bundleID: bundleID, format: format)
        _ = try await AppleScriptRunner.run(script, arguments: [input.path, to.path])
    }
}
