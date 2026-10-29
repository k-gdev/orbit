import SwiftUI

/// Three small bars that bounce while `active` (an app making sound, a live meter) and lie flat when
/// not. Animates only while active and on screen, and not at all with Reduce Motion.
struct LevelBars: View {
    let active: Bool
    var color: Color?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    init(active: Bool, color: Color? = nil) {
        self.active = active
        self.color = color
    }

    var body: some View {
        let tint = active ? (color ?? OrbitTheme.accent) : PanelStyle.colors(for: colorScheme).secondaryInk.opacity(0.6)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active || reduceMotion)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(tint)
                        .frame(width: 2, height: 10)
                        .scaleEffect(x: 1, y: height(bar: i, time: t), anchor: .bottom)
                }
            }
            .frame(height: 10)
        }
        .accessibilityHidden(true)
    }

    /// 0.35 at rest; while active a 1 s bounce per bar, a third of a cycle apart.
    private func height(bar: Int, time: TimeInterval) -> CGFloat {
        guard active else { return 0.35 }
        guard !reduceMotion else { return [0.6, 0.9, 0.5][bar] }
        let phase = (time - Double(bar) * 0.35) * 2 * .pi
        return 0.35 + 0.65 * (0.5 + 0.5 * sin(phase))
    }
}
