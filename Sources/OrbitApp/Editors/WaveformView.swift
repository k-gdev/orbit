import SwiftUI

/// An audio file's outline for the trim, split and bleep editors. `peaks` are 0...1 slices of the whole file; the view
/// shades what a trim keeps (`selection`), the marked bleep ranges and the split markers, and shows the playhead.
/// Clicking or dragging on it moves the playhead.
struct WaveformView: View {
    var peaks: [Float]
    var duration: Double
    var playhead: Double
    var selection: ClosedRange<Double>?
    var ranges: [ClosedRange<Double>] = []
    var markers: [Double] = []
    var onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            let x = { (t: Double) in ScrubberGeometry.x(t, duration: duration, width: width) }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.07))
                if let selection {
                    Rectangle().fill(OrbitTheme.accent.opacity(0.12))
                        .frame(width: max(x(selection.upperBound) - x(selection.lowerBound), 0), height: height)
                        .offset(x: x(selection.lowerBound))
                }
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, r in
                    Rectangle().fill(Color.red.opacity(0.22))
                        .frame(width: max(x(r.upperBound) - x(r.lowerBound), 2), height: height)
                        .offset(x: x(r.lowerBound))
                }
                bars(width: width, height: height)
                ForEach(Array(markers.enumerated()), id: \.offset) { _, t in
                    Rectangle().fill(OrbitTheme.accentMarker).frame(width: 2, height: height).offset(x: x(t) - 1)
                }
                Rectangle().fill(Color.primary.opacity(0.9)).frame(width: 2, height: height).offset(x: x(playhead) - 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                onSeek(ScrubberGeometry.time(atX: $0.location.x, duration: duration, width: width))
            })
        }
    }

    /// One bar per slice, mirrored about the middle, in the accent where the audio is kept, red where it is marked
    /// for a bleep, and gray elsewhere.
    private func bars(width: CGFloat, height: CGFloat) -> some View {
        Canvas { context, size in
            guard !peaks.isEmpty, duration > 0 else { return }
            let usable = max(size.width - 2 * ScrubberGeometry.inset, 1)
            let slot = usable / CGFloat(peaks.count)
            let barWidth = max(slot - 1, 1)
            for (index, peak) in peaks.enumerated() {
                let t = (Double(index) + 0.5) / Double(peaks.count) * duration
                let h = max(CGFloat(peak) * (size.height - 16), 2)
                let rect = CGRect(x: ScrubberGeometry.inset + CGFloat(index) * slot, y: (size.height - h) / 2,
                                  width: barWidth, height: h)
                let marked = ranges.contains { $0.contains(t) }
                let kept = selection.map { $0.contains(t) } ?? true
                let color: Color = marked ? .red : (kept ? OrbitTheme.accent : Color.primary.opacity(0.28))
                context.fill(Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 1.5)), with: .color(color))
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}
