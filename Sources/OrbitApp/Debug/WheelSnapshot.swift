import AppKit
import OrbitCore
import SwiftUI

/// Hidden command-line mode (ruling R21): renders the wheel offscreen to a PNG so
/// its layout can be checked where screen capture isn't available.
///
///     Orbit --snapshot-wheel <file> <convert|tools|actions> <out.png>
///           [--highlight N] [--subring N] [--pointer DX,DY]... [--dark] [--replace]
///
/// `--subring N` opens slice N's sub-ring; `--highlight` then picks a child of it,
/// otherwise a slice of the main ring. Each `--pointer` feeds an offset from the
/// centre (y up) to `updatePointer` and waits past the sub-ring delay, then the
/// resulting state is printed. Glass is drawn as a flat translucent fill because
/// materials don't render offscreen.
enum WheelSnapshot {
    static let flag = "--snapshot-wheel"
    static let usage = "usage: Orbit --snapshot-wheel <file> <convert|tools|actions> <out.png> [--highlight N] [--subring N] [--pointer DX,DY]... [--dark] [--replace]"

    struct Options {
        var file: URL
        var kind: WheelKind
        var output: URL
        var highlight: Int?
        var subRing: Int?
        var pointers: [CGVector] = []
        var dark = false
        var replace = false
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Renders and exits when `arguments` contain `--snapshot-wheel`; otherwise returns at once.
    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard let start = arguments.firstIndex(of: flag) else { return }
        let options: Options
        do {
            options = try parse(Array(arguments[(start + 1)...]))
        } catch {
            FileHandle.standardError.write(Data("\(error)\n\(usage)\n".utf8))
            exit(64)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await render(options)
                print("wrote \(options.output.path)")
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
                exit(1)
            }
        }
        NSApplication.shared.run()
    }

    static func parse(_ args: [String]) throws -> Options {
        guard args.count >= 3 else { throw Failure(description: "missing arguments") }
        guard let kind = WheelKind(rawValue: args[1]) else { throw Failure(description: "unknown wheel '\(args[1])'") }
        var options = Options(file: URL(fileURLWithPath: args[0]), kind: kind, output: URL(fileURLWithPath: args[2]))
        var rest = args.dropFirst(3).makeIterator()
        func number(after name: String) throws -> Int {
            guard let value = rest.next(), let n = Int(value), n >= 0 else { throw Failure(description: "\(name) needs a slice index") }
            return n
        }
        while let arg = rest.next() {
            switch arg {
            case "--highlight": options.highlight = try number(after: arg)
            case "--subring": options.subRing = try number(after: arg)
            case "--pointer":
                let parts = (rest.next() ?? "").split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 else { throw Failure(description: "--pointer needs DX,DY") }
                options.pointers.append(CGVector(dx: parts[0], dy: parts[1]))
            case "--dark": options.dark = true
            case "--replace": options.replace = true
            default: throw Failure(description: "unknown option '\(arg)'")
            }
        }
        return options
    }

    @MainActor
    static func render(_ options: Options) async throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: options.file.path) else { throw Failure(description: "no file at \(options.file.path)") }
        guard options.output.pathExtension.lowercased() == "png" else { throw Failure(description: "output must be a .png") }
        if fm.fileExists(atPath: options.output.path), !options.replace {
            throw Failure(description: "\(options.output.path) exists (pass --replace to overwrite it)")
        }

        let settings = SettingsStore()
        let capabilities = HelperLocator().locate(customFFmpegPath: settings.customFFmpegPath)
        let items = [DroppedItem(url: options.file)]
        let model = WheelModel()
        model.load(kind: options.kind,
                   content: SliceCatalog.content(for: items, wheel: options.kind, capabilities: capabilities,
                                                 settings: settings.catalogSettings),
                   items: items)
        let side = model.geometry.deadZoneRadius * 2
        model.thumbnail = await Thumbnails.image(for: options.file, size: CGSize(width: side, height: side))
        model.revealed = true

        let slices = model.content.slices
        if let parent = options.subRing {
            guard slices.indices.contains(parent), !slices[parent].children.isEmpty else {
                throw Failure(description: "slice \(parent) has no sub-ring (\(slices.count) slices)")
            }
            model.highlighted = parent
            model.openSubRing = parent
            if let child = options.highlight {
                guard slices[parent].children.indices.contains(child) else {
                    throw Failure(description: "sub-ring has \(slices[parent].children.count) slices")
                }
                model.subHighlighted = child
            }
        } else if let index = options.highlight {
            guard slices.indices.contains(index) else { throw Failure(description: "wheel has \(slices.count) slices") }
            model.highlighted = index
        }
        for offset in options.pointers {
            model.updatePointer(offset: offset)
            try await Task.sleep(for: model.subRingDelay + .milliseconds(100))
        }
        if !options.pointers.isEmpty {
            print("highlighted=\(model.highlighted.map(String.init) ?? "nil") openSubRing=\(model.openSubRing.map(String.init) ?? "nil") "
                + "subHighlighted=\(model.subHighlighted.map(String.init) ?? "nil") selected=\(model.selectedSlice?.id ?? "nil") hub=\"\(model.hubTitle)\"")
        }

        let panelSide = model.geometry.panelSide
        let view = ZStack {
            SnapshotBackdrop(dark: options.dark)
            WheelView(model: model)
        }
        .frame(width: panelSide, height: panelSide)
        .environment(\.glassRendering, .flat)
        .environment(\.colorScheme, options.dark ? .dark : .light)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "rendering failed")
        }
        try png.write(to: options.output, options: options.replace ? .atomic : .withoutOverwriting)
    }
}

/// A warm gradient like the hero video's desktop (or a dark one), so the
/// translucent petals have something to sit on.
private struct SnapshotBackdrop: View {
    let dark: Bool

    var body: some View {
        let colors: [Color] = dark
            ? [Color(red: 0.13, green: 0.15, blue: 0.22), Color(red: 0.25, green: 0.19, blue: 0.33)]
            : [Color(red: 0.94, green: 0.70, blue: 0.23), Color(red: 1.0, green: 0.42, blue: 0.33),
               Color(red: 0.66, green: 0.61, blue: 0.85)]
        LinearGradient(colors: colors, startPoint: .topTrailing, endPoint: .bottomLeading)
    }
}
