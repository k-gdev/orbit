import AppKit
import AVKit
import Combine
import OrbitCore
import SwiftUI

enum MediaEditMode {
    case trim, split, snapshot, bleep
}

/// State of the Trim, Split, Snapshot and Bleep editors: the part to keep (trim) or to cover (bleep), the split points,
/// and the playhead (snapshot), on top of a `MediaSession`.
@MainActor
final class MediaRangeModel: ObservableObject {
    let session: MediaSession
    let mode: MediaEditMode

    /// The selection handles. Trim keeps `start...end`; Bleep adds it to the ranges.
    @Published private(set) var start = 0.0
    @Published private(set) var end = 0.0
    /// Where Split cuts, in order.
    @Published private(set) var markers: [Double] = []
    /// What Bleep covers: sorted, and never overlapping.
    @Published private(set) var ranges: [ClosedRange<Double>] = []

    private var sessionChanges: AnyCancellable?

    init(session: MediaSession, mode: MediaEditMode) {
        self.session = session
        self.mode = mode
        sessionChanges = session.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
    }

    var duration: Double { session.duration }

    /// The shortest selection, and the closest two split points can be: a frame of video, a tenth of a second of audio.
    var minimumLength: Double { session.stepSize }

    func load() async {
        await session.load()
        configure()
    }

    /// Sets the handles once the length is known: the whole file for Trim, a short stretch in the middle for Bleep.
    func configure() {
        guard session.isReady else { return }
        start = 0
        end = duration
        if mode == .bleep {
            start = duration * 0.4
            end = min(max(start + min(1, duration * 0.1), start + minimumLength), duration)
        }
        syncWindow()
    }

    private func syncWindow() {
        session.playbackWindow = (mode == .trim || mode == .bleep) && end > start ? start...end : nil
    }

    // MARK: Selection

    func setStart(_ t: Double) {
        start = min(max(t, 0), max(end - minimumLength, 0))
        syncWindow()
    }

    func setEnd(_ t: Double) {
        end = min(max(t, start + minimumLength), duration)
        syncWindow()
    }

    func setStartToPlayhead() { setStart(session.playhead) }
    func setEndToPlayhead() { setEnd(session.playhead) }

    var selection: ClosedRange<Double>? {
        (mode == .trim || mode == .bleep) && session.isReady && end >= start ? start...end : nil
    }

    // MARK: Split

    var canAddMarker: Bool {
        let t = session.playhead
        return session.isReady && t >= minimumLength && t <= duration - minimumLength
            && !markers.contains { abs($0 - t) < minimumLength }
    }

    func addMarker() {
        guard canAddMarker else { return }
        markers = (markers + [session.playhead]).sorted()
    }

    func removeMarker(at index: Int) {
        guard markers.indices.contains(index) else { return }
        markers.remove(at: index)
    }

    /// `parts` equal pieces: replaces the markers with the cuts between them.
    func splitEvenly(into parts: Int) {
        guard session.isReady, parts >= 2 else { return }
        markers = (1..<parts).map { duration * Double($0) / Double(parts) }
    }

    // MARK: Bleep

    var canAddRange: Bool { session.isReady && end - start >= minimumLength }

    func addRange() {
        guard canAddRange else { return }
        ranges = Self.merged(ranges + [start...end])
    }

    func removeRange(at index: Int) {
        guard ranges.indices.contains(index) else { return }
        ranges.remove(at: index)
    }

    /// Sorted, with ranges that overlap or touch joined into one.
    static func merged(_ input: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for range in input.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }

    // MARK: Result

    /// What Apply hands to the job; nil while nothing valid is chosen (Apply is disabled).
    var parameters: ToolParameters? {
        guard session.isReady else { return nil }
        switch mode {
        case .trim:
            let whole = start <= 0.001 && end >= duration - 0.001
            return end - start >= minimumLength && !whole ? .timeRange(start...end) : nil
        case .split:
            return markers.isEmpty ? nil : .splitPoints(markers)
        case .snapshot:
            return .time(session.playhead)
        case .bleep:
            return ranges.isEmpty ? nil : .bleepRanges(ranges)
        }
    }

    var applyTitle: String {
        switch mode {
        case .trim: "Trim"
        case .split: "Split"
        case .snapshot: "Save Frame"
        case .bleep: "Bleep"
        }
    }

    /// A line for the footer: what Apply will make.
    var summary: String {
        guard session.isReady else { return "" }
        switch mode {
        case .trim: return "Keeps \(TimeFormat.string(end - start))"
        case .split: return markers.isEmpty ? "" : "Makes \(markers.count + 1) files"
        case .snapshot: return session.isAudio ? "" : "Full-size PNG"
        case .bleep: return ranges.isEmpty ? "" : ranges.count == 1 ? "1 range" : "\(ranges.count) ranges"
        }
    }

    func title(for kind: String) -> String {
        switch mode {
        case .trim: "Trim \(kind)"
        case .split: "Split \(kind)"
        case .snapshot: "Snapshot"
        case .bleep: "Bleep Audio"
        }
    }
}

struct MediaRangeEditor: View {
    static let width: CGFloat = 480

    let title: String
    @ObservedObject var model: MediaRangeModel
    let onClose: () -> Void
    let onApply: (ToolParameters) -> Void

    @Environment(\.glassRendering) private var rendering

    private var session: MediaSession { model.session }

    var body: some View {
        EditorShell(title: title, applyTitle: model.applyTitle, canApply: model.parameters != nil, onClose: onClose,
                    onApply: { if let parameters = model.parameters { onApply(parameters) } },
                    footerLeading: { Text(model.summary).font(.system(size: 12.5).monospacedDigit()).foregroundStyle(.secondary) },
                    content: {
            VStack(spacing: 12) {
                preview
                transport
                labels
                controls
            }
        })
    }

    /// The panel is sized once, when it opens, so every part has the same height whatever the file turns out to be.
    private var previewHeight: CGFloat { session.isAudio ? 110 : 250 }
    private var controlsHeight: CGFloat { mode == .split || mode == .bleep ? 102 : 30 }

    // MARK: Preview

    private var preview: some View {
        previewContent.frame(maxWidth: .infinity).frame(height: previewHeight)
    }

    @ViewBuilder
    private var previewContent: some View {
        switch session.status {
        case .loading(let message):
            placeholder { HStack(spacing: 8) { ProgressView().controlSize(.small); Text(message) } }
        case .failed(let message):
            placeholder { Text(message).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 16) }
        case .ready:
            if session.isAudio {
                WaveformView(peaks: session.peaks, duration: session.duration, playhead: session.playhead,
                             selection: model.selection, ranges: model.ranges, markers: model.markers,
                             onSeek: { session.seek(to: $0) })
            } else if let size = session.videoSize {
                videoFrame(size)
            }
        }
    }

    private func videoFrame(_ size: CGSize) -> some View {
        ZStack {
            Color.black
            if rendering == .live {
                PlayerView(player: session.player)
            } else if let still = session.still {
                Image(decorative: still, scale: 1).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(size, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .font(.system(size: 12.5)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07)))
    }

    // MARK: Scrubber

    private var transport: some View {
        HStack(spacing: 8) {
            if mode != .snapshot {
                Button { session.togglePlay() } label: {
                    Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color.primary.opacity(0.07)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!session.isReady)
                .help("Play or pause")
            }
            StepButton(forward: false) { session.step(-1) }.keyboardShortcut(.leftArrow, modifiers: [])
            ScrubberView(duration: session.duration, playhead: session.playhead, style: mode == .snapshot ? .plain : .range,
                         selection: model.selection, markers: model.markers, ranges: model.ranges,
                         onSeek: { session.seek(to: $0) },
                         onMoveStart: { model.setStart($0) }, onMoveEnd: { model.setEnd($0) })
            StepButton(forward: true) { session.step(1) }.keyboardShortcut(.rightArrow, modifiers: [])
        }
        .opacity(session.isReady ? 1 : 0.5)
        .allowsHitTesting(session.isReady)
    }

    private var mode: MediaEditMode { model.mode }

    /// Trim and Bleep show the handles' times at the ends and the playhead in the middle; the others show the
    /// playhead at the left and the length at the right.
    private var labels: some View {
        HStack {
            if mode == .trim || mode == .bleep {
                TimeLabel(seconds: model.start)
                TimeLabel(seconds: session.playhead, alignment: .center)
                TimeLabel(seconds: model.end, alignment: .trailing)
            } else {
                TimeLabel(seconds: session.playhead)
                TimeLabel(seconds: session.duration, alignment: .trailing)
            }
        }
    }

    // MARK: Per-mode controls

    private var controls: some View {
        controlsContent.frame(maxWidth: .infinity, alignment: .topLeading).frame(height: controlsHeight, alignment: .top)
    }

    @ViewBuilder
    private var controlsContent: some View {
        switch mode {
        case .trim:
            HStack(spacing: 8) {
                ChoiceChip(title: "Start here", selected: false) { model.setStartToPlayhead() }
                ChoiceChip(title: "End here", selected: false) { model.setEndToPlayhead() }
                Spacer(minLength: 8)
            }
        case .split:
            splitControls
        case .snapshot:
            Text("Scrub to the frame you want, then Save Frame.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .bleep:
            bleepControls
        }
    }

    private var splitControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ChoiceChip(title: "Add split here", selected: false) { model.addMarker() }
                    .disabled(!model.canAddMarker).opacity(model.canAddMarker ? 1 : 0.4)
                Spacer(minLength: 8)
                Text("Evenly").font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach([2, 3, 4, 5], id: \.self) { parts in
                    ChoiceChip(title: "\(parts)", selected: model.markers.count == parts - 1) { model.splitEvenly(into: parts) }
                }
            }
            .frame(height: 30)
            chipArea(empty: model.markers.isEmpty, hint: "Move the playhead and add a split, or split into equal parts.") {
                ForEach(Array(model.markers.enumerated()), id: \.offset) { index, t in
                    RemovableChip(title: TimeFormat.string(t)) { model.removeMarker(at: index) }
                }
            }
        }
    }

    private var bleepControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ChoiceChip(title: "Start here", selected: false) { model.setStartToPlayhead() }
                ChoiceChip(title: "End here", selected: false) { model.setEndToPlayhead() }
                Spacer(minLength: 8)
                ChoiceChip(title: "Add range", selected: true) { model.addRange() }
                    .disabled(!model.canAddRange).opacity(model.canAddRange ? 1 : 0.4)
            }
            .frame(height: 30)
            chipArea(empty: model.ranges.isEmpty, hint: "Drag the orange handles over a part, then Add range. Each range becomes a beep.") {
                ForEach(Array(model.ranges.enumerated()), id: \.offset) { index, range in
                    RemovableChip(title: "\(TimeFormat.string(range.lowerBound)) – \(TimeFormat.string(range.upperBound))") {
                        model.removeRange(at: index)
                    }
                }
            }
        }
    }

    /// The chips of what has been added, in an area that keeps its height however many there are (it scrolls).
    private func chipArea<Chips: View>(empty: Bool, hint text: String, @ViewBuilder chips: () -> Chips) -> some View {
        Group {
            if empty {
                hint(text)
            } else if rendering == .live {
                ScrollView(.vertical, showsIndicators: false) {
                    ChipFlow(spacing: 6) { chips() }.frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                // Snapshots cannot draw a ScrollView.
                ChipFlow(spacing: 6) { chips() }.frame(maxWidth: .infinity, alignment: .leading).clipped()
            }
        }
        .frame(height: 62, alignment: .top)
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A time (or a range of times) with a × that removes it.
struct RemovableChip: View {
    let title: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12, weight: .medium).monospacedDigit())
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 14, height: 14).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .foregroundStyle(.white)
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 4)
        .background(Capsule().fill(EditorStyle.accent))
    }
}

/// The video itself, without AVKit's controls.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
