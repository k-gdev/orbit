import AppKit
import OrbitCore

/// Hidden command-line mode (ruling R22b): runs a wheel slice on files through the
/// same `JobCoordinator` path as the app, with no windows, no Finder reveal and no
/// pasteboard writes, and prints one line per outcome.
///
///     Orbit --perform <file>... --wheel <convert|tools|actions> --slice <sliceID>
///
/// Prints `summary:`, `output:`, `failure:`, `clipboard:` or `error:` lines to stdout and
/// exits 0 once the job ends, or 1 when it failed.
///
///     Orbit --list-slices <file>... --wheel <convert|tools|actions>
///
/// Prints one `slice: <id>` line per runnable leaf slice for those files (`slice: <id> [editor]` when the slice opens an
/// editor window, which `--perform` cannot drive), then exits.
enum PerformCommand {
    static let flag = "--perform"
    static let listFlag = "--list-slices"
    static let usage = "usage: Orbit --perform <file>... --wheel <convert|tools|actions> --slice <sliceID>"

    struct Options {
        var files: [URL] = []
        var wheel: WheelKind?
        var sliceID: String?
    }

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        if let start = arguments.firstIndex(of: listFlag) {
            listSlices(parse(Array(arguments[(start + 1)...])))
        }
        guard let start = arguments.firstIndex(of: flag) else { return }
        let options = parse(Array(arguments[(start + 1)...]))
        guard !options.files.isEmpty, let wheel = options.wheel, let sliceID = options.sliceID else {
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(64)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)

        let settings = SettingsStore()
        let coordinator = JobCoordinator(settings: settings)
        let items = options.files.map(DroppedItem.init(url:))
        let content = SliceCatalog.content(for: items, wheel: wheel, capabilities: coordinator.capabilities,
                                           settings: settings.catalogSettings)
        guard let slice = find(sliceID, in: content.slices) else {
            print("error: no slice '\(sliceID)' on the \(wheel.rawValue) wheel for these files")
            exit(1)
        }
        coordinator.outcomeHandler = { outcome in
            switch outcome {
            case .finished(let result):
                print("summary: \(result.summary)")
                for url in result.outputs { print("output: \(url.path)") }
                for failure in result.failures { print("failure: \(failure.url.path) — \(failure.message)") }
                if let text = result.clipboardText { print("clipboard: \(text)") }
                exit(0)
            case .failed(let error):
                print("error: \(error.localizedDescription)")
                exit(1)
            case .cancelled:
                print("error: Cancelled.")
                exit(1)
            }
        }
        coordinator.perform(slice, items: items, near: .zero)
        withExtendedLifetime(coordinator) { NSApplication.shared.run() }
    }

    @MainActor
    private static func listSlices(_ options: Options) -> Never {
        guard !options.files.isEmpty, let wheel = options.wheel else {
            FileHandle.standardError.write(Data("usage: Orbit --list-slices <file>... --wheel <convert|tools|actions>\n".utf8))
            exit(64)
        }
        let settings = SettingsStore()
        let capabilities = JobCoordinator(settings: settings).capabilities
        let content = SliceCatalog.content(for: options.files.map(DroppedItem.init(url:)), wheel: wheel,
                                           capabilities: capabilities, settings: settings.catalogSettings)
        if let message = content.hubMessage { print("hub: \(message)") }
        func emit(_ slices: [Slice]) {
            for slice in slices {
                if slice.children.isEmpty { print("slice: \(slice.id)\(slice.editor != nil ? " [editor]" : "")") }
                else { emit(slice.children) }
            }
        }
        emit(content.slices)
        exit(0)
    }

    static func parse(_ args: [String]) -> Options {
        var options = Options()
        var rest = args.makeIterator()
        while let arg = rest.next() {
            switch arg {
            case "--wheel": options.wheel = rest.next().flatMap(WheelKind.init(rawValue:))
            case "--slice": options.sliceID = rest.next()
            default: options.files.append(URL(fileURLWithPath: arg))
            }
        }
        return options
    }

    private static func find(_ id: String, in slices: [Slice]) -> Slice? {
        for slice in slices {
            if slice.id == id { return slice }
            if let match = find(id, in: slice.children) { return match }
        }
        return nil
    }
}
