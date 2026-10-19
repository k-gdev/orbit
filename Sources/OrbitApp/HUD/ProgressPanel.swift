import AppKit
import Combine
import OrbitCore
import SwiftUI

/// What the progress panel shows; the running job updates it.
@MainActor
final class ProgressModel: ObservableObject {
    @Published var progress: JobProgress?
    var onCancel: () -> Void = {}
}

/// A glass rounded panel: × at top left, the title, the file name (with `n of m` for
/// batches) and a 4 pt orange bar.
struct ProgressPanelView: View {
    let title: String
    let fileName: String
    let countText: String?
    let fraction: Double
    let onCancel: () -> Void

    static let width: CGFloat = 360
    static let accent = Color(red: 1.0, green: 0.40, blue: 0.06)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Cancel")
                Text(title)
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(fileName).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let countText { Text(countText).foregroundStyle(.secondary).monospacedDigit() }
                }
                .font(.system(size: 14))
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: 4)
                    .overlay(alignment: .leading) {
                        GeometryReader { proxy in
                            Capsule().fill(Self.accent)
                                .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                                .animation(.linear(duration: 0.2), value: fraction)
                        }
                    }
            }
        }
        .padding(16)
        .frame(width: Self.width)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 26, style: .continuous)))
    }
}

private struct LiveProgressView: View {
    @ObservedObject var model: ProgressModel

    var body: some View {
        let p = model.progress
        ProgressPanelView(
            title: p?.title ?? "Working",
            fileName: p?.fileName ?? "",
            countText: (p?.itemCount ?? 1) > 1 ? "\((p?.itemIndex ?? 0) + 1) of \(p?.itemCount ?? 1)" : nil,
            fraction: p?.fraction ?? 0,
            onCancel: { model.onCancel() })
    }
}

/// Places progress panels at the drop point (clamped to the screen); panels stack 8 pt apart.
@MainActor
final class ProgressPanelController {
    private var panels: [HUDPanel] = []

    func show(model: ProgressModel, near point: CGPoint) -> HUDPanel {
        let panel = HUDPanel(rootView: LiveProgressView(model: model))
        let bounds = HUDPlacement.visibleFrame(containing: point)
        let size = panel.frame.size
        var frame = HUDPlacement.clamp(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                              width: size.width, height: size.height), to: bounds)
        // Move below any panel already in the way.
        for other in panels.sorted(by: { $0.frame.maxY > $1.frame.maxY }) where other.frame.insetBy(dx: -8, dy: -8).intersects(frame) {
            frame.origin.y = other.frame.minY - 8 - size.height
            frame = HUDPlacement.clamp(frame, to: bounds)
        }
        panel.setFrame(frame, display: false)
        panel.orderFrontRegardless()
        panels.append(panel)
        return panel
    }

    func close(_ panel: HUDPanel) {
        panel.orderOut(nil)
        panels.removeAll { $0 === panel }
    }
}
