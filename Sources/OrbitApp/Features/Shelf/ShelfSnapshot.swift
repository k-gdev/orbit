import AppKit
import OrbitCore
import SwiftUI

/// Fixture files for the Shelf's snapshots.
enum ShelfFixtures {
    /// Paths that need not exist (the tab and Settings snapshots write nothing): their icons come from the
    /// file types.
    static var demoURLs: [URL] {
        [
            URL(fileURLWithPath: "/Users/kevo/Desktop/Quarterly report.pdf"),
            URL(fileURLWithPath: "/Users/kevo/Downloads/Screenshot 2026-10-28 at 9.41.12.png"),
            URL(fileURLWithPath: "/Users/kevo/Documents/Trip notes.txt"),
            URL(fileURLWithPath: "/Users/kevo/Documents/Site assets", isDirectory: true),
            URL(fileURLWithPath: "/Users/kevo/Movies/Demo clip.mov"),
            URL(fileURLWithPath: "/Volumes/NAS/Archive 2026.zip"),
        ]
    }

    /// The demo item that shows as not reachable (its drive is not connected).
    static var demoOffline: Set<URL> { [URL(fileURLWithPath: "/Volumes/NAS/Archive 2026.zip")] }

    /// Real files in a fresh temp folder (removed at exit), so the floating shelf snapshot shows genuine
    /// Quick Look previews: two pictures, a one-page PDF, a text file, a folder and a movie placeholder.
    static func makeRealFiles() throws -> [URL] {
        let dir = SnapshotFixtures.directory()
        let fm = FileManager.default
        func write(_ data: Data, _ name: String) throws -> URL {
            let url = dir.appending(path: name, directoryHint: .notDirectory)
            try data.write(to: url, options: .withoutOverwriting)
            return url
        }
        let report = dir.appending(path: "Quarterly report.pdf", directoryHint: .notDirectory)
        try pdf(title: "Quarterly report").write(to: report, options: .withoutOverwriting)
        let screenshot = try write(try png(width: 640, height: 400, top: (0.36, 0.55, 0.85), bottom: (0.78, 0.55, 0.90)),
                                   "Screenshot 2026-10-28 at 9.41.12.png")
        let notes = try write(Data("Flights, hotel, the long list of things to pack.\n".utf8), "Trip notes.txt")
        let folder = dir.appending(path: "Site assets", directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let logo = try write(try png(width: 320, height: 320, top: (0.96, 0.62, 0.35), bottom: (0.85, 0.30, 0.45)), "Logo.png")
        let clip = try write(Data(), "Demo clip.mov")
        return [report, screenshot, notes, folder, logo, clip]
    }

    /// The first `count` of `makeRealFiles()` (the floating shelf's default size fits five across).
    static func makeRealFiles(count: Int) throws -> [URL] {
        Array(try makeRealFiles().prefix(count))
    }

    private static func png(width: Int, height: Int, top: (Double, Double, Double), bottom: (Double, Double, Double)) throws -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { throw SnapshotRenderer.Failure(description: "no bitmap") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let gradient = NSGradient(starting: NSColor(deviceRed: top.0, green: top.1, blue: top.2, alpha: 1),
                                  ending: NSColor(deviceRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1))
        gradient?.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw SnapshotRenderer.Failure(description: "png failed") }
        return data
    }

    private static func pdf(title: String) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw SnapshotRenderer.Failure(description: "pdf failed") }
        context.beginPDFPage(nil)
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSString(string: title).draw(at: NSPoint(x: 72, y: 700), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 34)])
        for line in 0..<14 {
            NSString(string: "Revenue line \(line + 1)   ........   \(1000 + line * 137)").draw(
                at: NSPoint(x: 72, y: 640 - CGFloat(line) * 28), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

/// Hidden command-line modes that render the Shelf offscreen (nothing is shown on screen, no real files
/// are touched; fixture files live in a temp folder that is removed at exit).
///
///     Orbit --snapshot-shelf <out.png> [--empty] [--targeted] [--hover N] [--count N] [--offline N] [--dark] [--replace]
///     Orbit --snapshot-shelf-wheel <on|off> <out.png> [--highlight N] [--dark] [--replace]
///
/// `--snapshot-shelf` draws the floating shelf over real fixture files (`--targeted`: a file drag is over
/// it; `--hover N`: the Nth tile is hovered, showing its ✕). `--snapshot-shelf-wheel` draws the wheel's
/// Actions ring with the Shelf action (`on`) or without it (`off`) and prints the ring's slice titles.
enum ShelfSnapshot {
    static let shelfFlag = "--snapshot-shelf"
    static let wheelFlag = "--snapshot-shelf-wheel"
    static let usage = """
        usage: Orbit --snapshot-shelf <out.png> [--empty] [--targeted] [--hover N] [--count N] [--offline N] [--dark] [--replace]
               Orbit --snapshot-shelf-wheel <on|off> <out.png> [--highlight N] [--dark] [--replace]
        """

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        let isWheel = arguments.contains(wheelFlag)
        guard isWheel || arguments.contains(shelfFlag) else { return }
        let flag = isWheel ? wheelFlag : shelfFlag
        guard let start = arguments.firstIndex(of: flag) else { return }
        let args = Array(arguments[(start + 1)...])
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                if isWheel {
                    try renderWheel(args)
                } else {
                    try await renderShelf(args)
                }
                exit(0)
            } catch let failure as UsageFailure {
                FileHandle.standardError.write(Data("\(failure.message)\n\(usage)\n".utf8))
                exit(64)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    private struct UsageFailure: Error { let message: String }

    private static func output(_ path: String?, replace: Bool) throws -> URL {
        guard let path, !path.hasPrefix("--") else { throw UsageFailure(message: "missing output path") }
        let url = URL(fileURLWithPath: path)
        guard url.pathExtension.lowercased() == "png" else { throw UsageFailure(message: "output must be a .png") }
        if FileManager.default.fileExists(atPath: url.path), !replace {
            throw SnapshotRenderer.Failure(description: "\(url.path) exists (pass --replace to overwrite it)")
        }
        return url
    }

    private static func number(after flag: String, in args: [String]) throws -> Int? {
        guard let index = args.firstIndex(of: flag) else { return nil }
        guard args.indices.contains(index + 1), let n = Int(args[index + 1]), n >= 0 else {
            throw UsageFailure(message: "\(flag) needs a number")
        }
        return n
    }

    // MARK: Floating shelf

    @MainActor
    private static func renderShelf(_ args: [String]) async throws {
        let replace = args.contains("--replace")
        let dark = args.contains("--dark")
        let url = try output(args.first, replace: replace)
        let hover = try number(after: "--hover", in: args)

        let count = try number(after: "--count", in: args) ?? 5
        let offline = try number(after: "--offline", in: args) ?? 0
        let files = args.contains("--empty") ? [] : try ShelfFixtures.makeRealFiles(count: count)
        ShelfIcon.prime(files) // the real icons, as the app reads them off the main thread
        for file in files { _ = await ShelfThumbnails.load(file, side: 48) } // so previews are in place when drawn
        // `--offline N` shows the last N as if their drive were not connected.
        let model = ShelfModel.fixture(files, unreachable: Set(files.suffix(offline)))
        model.isDropTargeted = args.contains("--targeted")

        // The real panel content: the SwiftUI shelf plus the AppKit resize grip.
        let size = ShelfPlacement.defaultSize
        let strip = ShelfContentPreview(model: model, dark: dark, hover: hover.flatMap { files.indices.contains($0) ? files[$0] : nil })
            .frame(width: size.width, height: size.height)
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            .padding(36)
            .background(Backdrop(dark: dark))
        let data = try SnapshotRenderer.png(of: strip, size: CGSize(width: size.width + 72, height: size.height + 72), dark: dark)
        try SnapshotRenderer.write(data, to: url, replace: replace)
        print("wrote \(url.path)")
    }

    // MARK: Wheel

    @MainActor
    private static func renderWheel(_ args: [String]) throws {
        guard let state = args.first, state == "on" || state == "off" else { throw UsageFailure(message: "expected on or off") }
        let replace = args.contains("--replace")
        let dark = args.contains("--dark")
        let url = try output(args.dropFirst().first, replace: replace)
        let highlight = try number(after: "--highlight", in: args)

        var catalog = CatalogSettings(favouriteFolders: [URL(fileURLWithPath: "/Users/kevo/Desktop", isDirectory: true),
                                                         URL(fileURLWithPath: "/Users/kevo/Downloads", isDirectory: true)])
        catalog.showShelfAction = state == "on"
        let items = [DroppedItem(url: URL(fileURLWithPath: "/Users/kevo/Desktop/Quarterly report.pdf"))]
        let content = SliceCatalog.content(for: items, wheel: .actions, capabilities: .none, settings: catalog)
        print("actions ring (\(state)): " + content.slices.map(\.title).joined(separator: ", "))

        let model = WheelModel()
        model.load(kind: .actions, content: content, items: items)
        model.revealed = true
        if let highlight, content.slices.indices.contains(highlight) { model.highlighted = highlight }
        let side = model.geometry.panelSide
        let view = ZStack {
            Backdrop(dark: dark)
            WheelView(model: model)
        }
        .frame(width: side, height: side)
        .environment(\.glassRendering, .flat)
        .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapshotRenderer.Failure(description: "rendering failed")
        }
        try SnapshotRenderer.write(png, to: url, replace: replace)
        print("wrote \(url.path)")
    }
}

/// The floating shelf's real content view (`ShelfContentView`) as a SwiftUI view, for snapshots.
private struct ShelfContentPreview: NSViewRepresentable {
    let model: ShelfModel
    let dark: Bool
    let hover: URL?

    func makeNSView(context: Context) -> ShelfContentView {
        // The inner hosting view is its own SwiftUI root: give it the snapshot's environment.
        ShelfContentView(model: model, close: {}, decorate: { content in
            AnyView(content
                .environment(\.glassRendering, .flat)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.shelfPreviewHover, hover))
        })
    }

    func updateNSView(_ view: ShelfContentView, context: Context) {}
}

/// A soft desktop-like gradient behind the snapshots.
private struct Backdrop: View {
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.11, green: 0.09, blue: 0.22), Color(red: 0.05, green: 0.04, blue: 0.10)]
                                        : [Color(red: 0.36, green: 0.27, blue: 0.62), Color(red: 0.16, green: 0.12, blue: 0.30)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.96, green: 0.70, blue: 0.56).opacity(dark ? 0.35 : 0.9), .clear],
                           center: UnitPoint(x: 0.12, y: 0.15), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Color(red: 0.56, green: 0.44, blue: 0.77).opacity(dark ? 0.45 : 0.9), .clear],
                           center: UnitPoint(x: 0.88, y: 0.3), startRadius: 0, endRadius: 340)
        }
    }
}
