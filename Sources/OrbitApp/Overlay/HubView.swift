import SwiftUI

/// The wheel's centre: the dragged file's thumbnail in a circle, with a pill that
/// names the slice under the pointer (or explains why the wheel is empty).
struct HubView: View {
    let thumbnail: NSImage?
    let title: String
    /// Shown instead of `title` when the wheel has no slices.
    let message: String?
    let multipleItems: Bool
    let radius: Double

    var body: some View {
        ZStack {
            GlassBackground(shape: Circle())
            picture
                .frame(width: (radius - 5) * 2, height: (radius - 5) * 2)
                .clipShape(Circle())
        }
        .frame(width: radius * 2, height: radius * 2)
        .overlay {
            if let message {
                HubPill(text: message, maxWidth: 240, lineLimit: 2)
                    .offset(y: radius + 30)
            } else {
                HubPill(text: title, maxWidth: radius * 2 + 44, lineLimit: 1)
                    .offset(y: radius * 0.5)
            }
        }
    }

    @ViewBuilder private var picture: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: multipleItems ? "doc.on.doc" : "doc")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }
}

private struct HubPill: View {
    let text: String
    let maxWidth: Double
    let lineLimit: Int

    var body: some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .multilineTextAlignment(.center)
            .lineLimit(lineLimit)
            .truncationMode(.middle)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(minWidth: 72)
            .background(GlassBackground(shape: Capsule(), tintOpacity: 0.4))
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .frame(width: maxWidth)
    }
}
