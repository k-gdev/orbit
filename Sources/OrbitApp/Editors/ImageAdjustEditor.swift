import Combine
import OrbitCore
import SwiftUI

/// State of the Adjust editor: the settings, and a live preview that `AdjustRenderer` renders on the
/// 1024 px proxy. Changes made during a render coalesce into one more render.
@MainActor
final class AdjustModel: ObservableObject {
    @Published var image: EditorImage?
    @Published var loadError: String?
    @Published var settings = AdjustSettings() { didSet { scheduleRender() } }
    @Published private(set) var preview: CGImage?
    /// True while the pointer is held down on the preview.
    @Published var showOriginal = false

    private var loop: PreviewLoop?

    var isIdentity: Bool { settings == AdjustSettings() }

    func load(_ url: URL) async {
        do {
            image = try await Task.detached(priority: .userInitiated) { try EditorImage.load(url) }.value
            scheduleRender()
        } catch {
            loadError = error.localizedDescription
        }
    }

    func scheduleRender() {
        guard let source = image?.proxy else { return }
        let current = settings
        if loop == nil { loop = PreviewLoop { [weak self] in self?.preview = $0 } }
        loop?.submit { try? AdjustRenderer.render(source, current) }
    }

    /// Renders synchronously (headless snapshots).
    func renderNow() {
        guard let image else { return }
        preview = try? AdjustRenderer.render(image.proxy, settings)
    }

    /// Size of the result in pixels, after any quarter turn.
    var outputSize: CGSize? {
        guard let size = image?.pixelSize else { return nil }
        return settings.quarterTurns % 2 == 0 ? size : CGSize(width: size.height, height: size.width)
    }
}

struct ImageAdjustEditor: View {
    static let width: CGFloat = 480

    let title: String
    @ObservedObject var model: AdjustModel
    let onClose: () -> Void
    let onApply: (AdjustSettings) -> Void

    var body: some View {
        EditorShell(title: title, canApply: model.image != nil && !model.isIdentity, onClose: onClose,
                    onApply: { onApply(model.settings) }) {
            VStack(spacing: 14) {
                previewArea
                HStack {
                    chip("Reset", selected: false) { model.settings = AdjustSettings() }
                    Spacer()
                    if let size = model.outputSize {
                        Text("\(Int(size.width)) × \(Int(size.height)) px")
                            .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                VStack(spacing: 8) {
                    slider("Exposure", $model.settings.exposure, -2...2, step: 0.05) { String(format: "%+.2f", $0) }
                    slider("Contrast", $model.settings.contrast, 0.5...1.5, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                    slider("Saturation", $model.settings.saturation, 0...2, step: 0.01) { "\(Int(($0 * 100).rounded()))%" }
                    slider("Warmth", $model.settings.warmth, -1...1, step: 0.02) { String(format: "%+.2f", $0) }
                }
                HStack(spacing: 18) {
                    toggle("Auto", $model.settings.auto)
                    toggle("B&W", $model.settings.blackAndWhite)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    ToolButton(symbol: "rotate.left", title: "Rotate", selected: false) { model.settings.rotate(clockwise: false) }
                    ToolButton(symbol: "rotate.right", title: "Rotate", selected: false) { model.settings.rotate(clockwise: true) }
                    ToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", title: "Flip H",
                               selected: model.settings.isFlippedHorizontallyInPreview) { model.settings.flipPreviewHorizontally() }
                    ToolButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", title: "Flip V",
                               selected: model.settings.isFlippedVerticallyInPreview) { model.settings.flipPreviewVertically() }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var previewArea: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topLeading) {
                PreviewImage(image: model.showOriginal ? model.image?.proxy : (model.preview ?? model.image?.proxy))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.showOriginal {
                    Text("Original")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                        .padding(8)
                }
                if let error = model.loadError {
                    Text(error).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 280)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !model.showOriginal { model.showOriginal = true } }
                .onEnded { _ in model.showOriginal = false })
            Text("Press and hold the photo to see the original")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        ChoiceChip(title: title, selected: selected, action: action)
    }

    private func toggle(_ title: String, _ isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 14))
            OrbitSwitch(isOn: isOn)
        }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
                        format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14)).frame(width: 78, alignment: .leading)
            OrbitSlider(value: value, range: range, step: step)
            Text(format(value.wrappedValue))
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
        }
    }
}
