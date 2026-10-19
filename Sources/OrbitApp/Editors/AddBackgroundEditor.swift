import Combine
import OrbitCore
import SwiftUI

/// State of the Add BG editor. The subject is cut out once when the editor opens; every change then
/// recomposes the preview with `BackgroundComposer` on the 1024 px proxy.
@MainActor
final class BackgroundModel: ObservableObject {
    enum Mode { case solid, gradient, blur }

    enum Status: Equatable {
        case loading
        case ready
        case failed(String)
    }

    static let blurRange: ClosedRange<Double> = 0...40
    static let presets: [(name: String, rgba: RGBA)] = [
        ("White", RGBA(r: 1, g: 1, b: 1, a: 1)),
        ("Black", RGBA(r: 0, g: 0, b: 0, a: 1)),
        ("Orbit orange", EditorStyle.accentRGBA),
    ]

    @Published private(set) var status = Status.loading
    @Published private(set) var image: EditorImage?
    @Published private(set) var preview: CGImage?
    /// Why the last preview render failed; nil when it succeeded. The preview area shows it.
    @Published private(set) var previewError: String?
    @Published var mode = Mode.solid { didSet { scheduleRender() } }
    @Published var solid = Color.white { didSet { scheduleRender() } }
    @Published var gradientTop = Color(red: 1, green: 0.78, blue: 0.35) { didSet { scheduleRender() } }
    @Published var gradientBottom = Color(red: 1, green: 0.36, blue: 0.10) { didSet { scheduleRender() } }
    @Published var blur = 20.0 { didSet { scheduleRender() } }

    private var subject: CGImage?
    private var loop: PreviewLoop?
    /// Composes the preview; replaced in the live check to make a render fail.
    var composer: @Sendable (CGImage, CGImage, OrbitCore.BackgroundStyle) throws -> CGImage = {
        try BackgroundComposer.compose(subject: $0, original: $1, style: $2)
    }

    /// The style for the proxy preview.
    private var previewStyle: OrbitCore.BackgroundStyle {
        switch mode {
        case .solid: .solid(RGBA(solid))
        case .gradient: .gradient(RGBA(gradientTop), RGBA(gradientBottom))
        case .blur: .blur(radius: blur)
        }
    }

    /// The style for the job. The blur is scaled up from the proxy to the full image so that it looks as it did in the preview.
    var jobStyle: OrbitCore.BackgroundStyle {
        if case .blur(let radius) = previewStyle, let scale = image?.proxyScale, scale > 0 {
            return .blur(radius: radius / scale)
        }
        return previewStyle
    }

    var canApply: Bool { status == .ready }

    /// Opens `url`: loads the proxy, then finds the subject (an image that already has transparency is its own subject).
    func load(_ url: URL) async {
        let outcome: Result<(EditorImage, CGImage), Error> = await Task.detached(priority: .userInitiated) {
            Result {
                let image = try EditorImage.load(url)
                if image.hasTransparency { return (image, image.proxy) }
                let cutout = try BackgroundRemover.cutout(url)
                return (image, try EditorImage.make(from: cutout).proxy)
            }
        }.value
        switch outcome {
        case .success(let (image, subject)):
            set(image: image, subject: subject)
            scheduleRender()
        case .failure(let error):
            status = .failed(error.localizedDescription)
        }
    }

    /// Supplies the images directly (headless snapshots).
    func set(image: EditorImage, subject: CGImage) {
        self.image = image
        self.subject = subject
        status = .ready
    }

    func scheduleRender() {
        guard let original = image?.proxy, let subject else { return }
        let style = previewStyle
        let compose = composer
        if loop == nil { loop = PreviewLoop { [weak self] in self?.receive($0) } }
        loop?.submit { try compose(subject, original, style) }
    }

    private func receive(_ result: Result<CGImage, Error>) {
        switch result {
        case .success(let image):
            preview = image
            previewError = nil
        case .failure(let error):
            previewError = "Couldn't render the preview: \(error.localizedDescription)"
        }
    }

    /// Renders synchronously (headless snapshots).
    func renderNow() {
        guard let original = image?.proxy, let subject else { return }
        receive(Result { try composer(subject, original, previewStyle) })
    }
}

struct AddBackgroundEditor: View {
    static let width: CGFloat = 480

    let title: String
    @ObservedObject var model: BackgroundModel
    let onClose: () -> Void
    let onApply: (OrbitCore.BackgroundStyle) -> Void

    var body: some View {
        EditorShell(title: title, canApply: model.canApply, onClose: onClose,
                    onApply: { onApply(model.jobStyle) }) {
            VStack(spacing: 14) {
                previewArea
                VStack(spacing: 12) {
                    row("Color") { colorRow }
                    row("Gradient") { gradientRow }
                    row("Blur") { blurRow }
                }
            }
        }
    }

    // MARK: Preview

    private var previewArea: some View {
        ZStack {
            PreviewImage(image: model.preview ?? model.image?.proxy)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            switch model.status {
            case .loading:
                if model.image != nil || model.preview == nil {
                    Text("Finding the subject…")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(.regularMaterial))
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 13, weight: .medium)).multilineTextAlignment(.center)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
            case .ready:
                if let error = model.previewError {
                    PreviewErrorBanner(message: error).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
        .frame(height: 280)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Controls

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 14)).frame(width: 78, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }

    private var colorRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(BackgroundModel.presets.enumerated()), id: \.offset) { _, preset in
                let chosen = model.mode == .solid && RGBA(model.solid) == preset.rgba
                Button {
                    model.solid = preset.rgba.color
                    model.mode = .solid
                } label: {
                    Circle().fill(preset.rgba.color)
                        .frame(width: 28, height: 28)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        .padding(3)
                        .overlay(Circle().stroke(EditorStyle.accent, lineWidth: chosen ? 2 : 0))
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
            OrbitColorWell(color: Binding(get: { model.solid },
                                          set: { model.solid = $0; model.mode = .solid }), help: "Custom color")
                .padding(3)
                .overlay(Circle().stroke(EditorStyle.accent,
                                         lineWidth: model.mode == .solid && !BackgroundModel.presets.contains { $0.rgba == RGBA(model.solid) } ? 2 : 0))
        }
    }

    private var gradientRow: some View {
        HStack(spacing: 10) {
            Button { model.mode = .gradient } label: {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(LinearGradient(colors: [model.gradientTop, model.gradientBottom], startPoint: .top, endPoint: .bottom))
                    .frame(width: 56, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.primary.opacity(0.25), lineWidth: 1))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(EditorStyle.accent, lineWidth: model.mode == .gradient ? 2 : 0))
            }
            .buttonStyle(.plain)
            .help("Use the gradient")
            OrbitColorWell(color: Binding(get: { model.gradientTop },
                                          set: { model.gradientTop = $0; model.mode = .gradient }), help: "Top color")
            OrbitColorWell(color: Binding(get: { model.gradientBottom },
                                          set: { model.gradientBottom = $0; model.mode = .gradient }), help: "Bottom color")
        }
    }

    private var blurRow: some View {
        HStack(spacing: 12) {
            OrbitSlider(value: Binding(get: { model.blur }, set: { model.blur = $0; model.mode = .blur }),
                        range: BackgroundModel.blurRange, step: 1)
            Text("\(Int(model.blur))")
                .font(.system(size: 13).monospacedDigit())
                .foregroundStyle(model.mode == .blur ? Color.primary : Color.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }
}
