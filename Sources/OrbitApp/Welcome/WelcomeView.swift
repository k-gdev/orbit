import AppKit
import OrbitCore
import SwiftUI

/// The first-launch panel that asks for Full Disk Access (one grant instead of a prompt per folder).
/// Pure presentation: `WelcomeWindowController` owns the polling and passes `granted` in.
struct WelcomeView: View {
    static let width: CGFloat = 440

    let granted: Bool
    let onOpenSettings: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            logo
            Text(granted ? "You're all set ✓" : "Welcome to Orbit")
                .font(.system(size: 22, weight: .semibold))
            if granted {
                Text("Orbit can reach your folders without asking again.")
                    .font(.system(size: 14)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                pending
            }
        }
        .padding(.horizontal, 32).padding(.top, 30).padding(.bottom, 26)
        .frame(width: Self.width)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous), tintOpacity: 0.3))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    @ViewBuilder private var pending: some View {
        Text("Orbit converts and edits the files you drop on it, wherever they live. macOS normally asks separately for your Desktop, Documents, Downloads and other folders. Turn on Full Disk Access once and you won't be asked again.")
            .font(.system(size: 14)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        VStack(alignment: .leading, spacing: 8) {
            step(1, "Click Open Privacy Settings")
            step(2, "Turn on Orbit under Full Disk Access")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.06)))
        Text("Don't see Orbit? Click +, choose Orbit in Applications.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        VStack(spacing: 8) {
            Button(action: onOpenSettings) {
                Text("Open Privacy Settings")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(OrbitTheme.accent))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            Button(action: onNotNow) {
                Text("Not now — ask me per folder")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(OrbitTheme.accent))
            Text(text).font(.system(size: 14))
        }
    }

    /// The menu bar glyph, large and white, on an accent tile.
    private var logo: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(OrbitTheme.accent)
            .frame(width: 64, height: 64)
            .overlay {
                Image(nsImage: Self.glyph)
                    .renderingMode(.template)
                    .resizable()
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }
    }

    private static let glyph: NSImage = {
        let image = NSImage(size: NSSize(width: OrbitGlyph.side, height: OrbitGlyph.side))
        if let rep = OrbitGlyph.bitmap(busy: false, scale: 8) { image.addRepresentation(rep) }
        image.isTemplate = true
        return image
    }()
}
