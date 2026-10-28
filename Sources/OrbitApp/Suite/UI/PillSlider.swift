import AppKit
import OrbitCore
import SwiftUI

/// Orbit's signature control: a Control Center–style capsule slider for volume, brightness and levels.
///
/// - The white fill grows from the left and is never narrower than a circle, which holds the `leading`
///   content (an SF Symbol, or an app icon). An optional `label` (an app name, `LevelBars`) follows it.
/// - The value text (`valueText(value)`) sits inside on the right; it turns accent-coloured when boosted.
/// - Past `scale.boostStart` (100) the track is striped in the accent colour (`Stripes`), whether or not
///   the fill reaches it, and the filled part of that zone is tinted.
/// - Dragging anywhere on the pill sets the value (the fill's end follows the pointer); a mouse wheel
///   nudges it by `scale.wheelStep`; a sideways trackpad swipe moves it continuously (vertical trackpad
///   scrolling is left to the enclosing scroll view). VoiceOver increments and decrements it.
/// - `onLeadingTap` makes the leading content a button (for example click the app icon to mute).
/// - `onEditingEnded` fires when a drag ends or a burst of scrolling settles: commit expensive work
///   (DDC writes, persisting) there and apply cheap previews in the binding's setter.
///
/// All value math goes through `PillScale` and `PillTrack` (OrbitCore, tested).
///
///     PillSlider(value: $volume, scale: PillScale(maximum: 150), height: 34,
///                leading: AnyView(AppIcon(app)), label: AnyView(Text(app.name)),
///                valueText: { "\(Int($0))%" }, onLeadingTap: { app.toggleMute() })
struct PillSlider: View {
    @Binding var value: Double
    let scale: PillScale
    var step: Double
    var height: CGFloat
    var isDimmed: Bool
    let leading: AnyView
    var label: AnyView?
    let valueText: (Double) -> String
    var onLeadingTap: (() -> Void)?
    var onEditingEnded: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var wheel = WheelState()

    init(value: Binding<Double>, scale: PillScale, step: Double = 1, height: CGFloat = 30, isDimmed: Bool = false,
         leading: AnyView, label: AnyView? = nil, valueText: @escaping (Double) -> String,
         onLeadingTap: (() -> Void)? = nil, onEditingEnded: (() -> Void)? = nil) {
        _value = value
        self.scale = scale
        self.step = step
        self.height = height
        self.isDimmed = isDimmed
        self.leading = leading
        self.label = label
        self.valueText = valueText
        self.onLeadingTap = onLeadingTap
        self.onEditingEnded = onEditingEnded
    }

    /// A pill whose leading content is an SF Symbol.
    init(value: Binding<Double>, scale: PillScale, step: Double = 1, height: CGFloat = 30, isDimmed: Bool = false,
         systemImage: String, label: AnyView? = nil, valueText: @escaping (Double) -> String,
         onLeadingTap: (() -> Void)? = nil, onEditingEnded: (() -> Void)? = nil) {
        self.init(value: value, scale: scale, step: step, height: height, isDimmed: isDimmed,
                  leading: AnyView(Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))),
                  label: label, valueText: valueText, onLeadingTap: onLeadingTap, onEditingEnded: onEditingEnded)
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let track = PillTrack(width: Double(width), height: Double(height))
            let fillWidth = CGFloat(track.fillWidth(forFraction: scale.fraction(for: value)))
            let boostX = scale.hasBoost ? CGFloat(track.fillWidth(forFraction: scale.boostStartFraction)) : width
            pill(width: width, fillWidth: fillWidth, boostX: boostX)
                .contentShape(Capsule())
                .gesture(dragGesture(track))
                .onHover { inside in
                    if inside { installWheelMonitor(track) } else { removeWheelMonitor() }
                }
        }
        .frame(height: height)
        .onDisappear { removeWheelMonitor() }
        .accessibilityElement(children: .ignore)
        .accessibilityValue(valueText(value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: set(scale.wheelNudged(value, notches: 1, step: step)); onEditingEnded?()
            case .decrement: set(scale.wheelNudged(value, notches: -1, step: step)); onEditingEnded?()
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Activate icon") { onLeadingTap?() }
    }

    // MARK: Drawing

    private func pill(width: CGFloat, fillWidth: CGFloat, boostX: CGFloat) -> some View {
        let style = PanelStyle.colors(for: colorScheme)
        let dark = colorScheme == .dark
        return ZStack(alignment: .leading) {
            Capsule().fill(style.trackFill)
            if scale.hasBoost {
                Stripes(spacing: 9, stripeWidth: 4.5)
                    .fill(OrbitTheme.accent.opacity(dark ? 0.42 : 0.26))
                    .frame(width: max(width - boostX, 0))
                    .offset(x: boostX)
            }
            Capsule()
                .fill(style.pillFill.opacity(isDimmed ? 0.55 : 1))
                .overlay(alignment: .leading) {
                    if scale.isBoosted(value) {
                        Rectangle().fill(OrbitTheme.accent.opacity(dark ? 0.30 : 0.18))
                            .frame(width: max(fillWidth - boostX, 0))
                            .offset(x: boostX)
                    }
                }
                .clipShape(Capsule())
                .frame(width: fillWidth)
                .shadow(color: .black.opacity(isDimmed ? 0 : 0.14), radius: 1.5, y: 0.5)
            // The content is drawn twice: in the track's ink, then in the fill's ink masked to the fill,
            // so text and icons stay readable wherever the fill ends (dark mode's fill is near white).
            content(ink: style.inkOnTrack, interactive: true)
                .overlay(alignment: .leading) {
                    content(ink: style.inkOnFill, interactive: false)
                        .mask(alignment: .leading) { Rectangle().frame(width: fillWidth) }
                        .allowsHitTesting(false)
                }
        }
        .frame(width: width, height: height)
        .clipShape(Capsule())
    }

    private func content(ink: Color, interactive: Bool) -> some View {
        HStack(spacing: 6) {
            leadingView(interactive: interactive)
                .frame(width: height, height: height)
            if let label {
                label.font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(valueText(value))
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(scale.isBoosted(value) ? boostedInk(onFill: ink == PanelStyle.colors(for: colorScheme).inkOnFill) : ink)
                .padding(.trailing, height * 0.38)
        }
        .foregroundStyle(ink)
        .opacity(isDimmed ? 0.55 : 1)
    }

    /// Boosted value text: the accent, lifted for dark mode where it sits on the dark track.
    private func boostedInk(onFill: Bool) -> Color {
        onFill ? OrbitTheme.accent : PanelStyle.accent(for: colorScheme)
    }

    @ViewBuilder private func leadingView(interactive: Bool) -> some View {
        if let onLeadingTap, interactive {
            Button(action: onLeadingTap) {
                leading.frame(width: height, height: height).contentShape(Circle())
            }
            .buttonStyle(.plain)
        } else {
            leading
        }
    }

    // MARK: Input

    private func set(_ newValue: Double) {
        if newValue != value { value = newValue }
    }

    private func dragGesture(_ track: PillTrack) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                set(scale.value(forFraction: track.fraction(atX: Double(drag.location.x)), step: step))
            }
            .onEnded { _ in onEditingEnded?() }
    }

    /// Scroll input arrives through a local monitor, installed only while the pointer is over this pill.
    private func installWheelMonitor(_ track: PillTrack) {
        removeWheelMonitor()
        let wheel = self.wheel
        wheel.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleScroll(event, track: track) ? nil : event
        }
    }

    private func removeWheelMonitor() {
        if let monitor = wheel.monitor { NSEvent.removeMonitor(monitor) }
        wheel.monitor = nil
        wheel.residual = 0
    }

    /// Returns true when the event moved the value (and is consumed).
    private func handleScroll(_ event: NSEvent, track: PillTrack) -> Bool {
        if !event.hasPreciseScrollingDeltas {
            // Mouse wheel: one notch per event, away from you = up.
            let up = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            guard up != 0 else { return false }
            let notches = up > 0 ? max(1, up.rounded()) : min(-1, up.rounded())
            set(scale.wheelNudged(value, notches: Double(notches), step: step))
            scheduleEditingEnded()
            return true
        }
        // Trackpad: only a mostly-sideways swipe adjusts; fingers right = up.
        let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
        guard dx != 0, abs(dx) > abs(dy) * 1.5 else { return false }
        let right = event.isDirectionInvertedFromDevice ? dx : -dx
        wheel.residual += Double(right) / max(track.travel, 1) * scale.maximum
        let whole = step > 0 ? (wheel.residual / step).rounded(.towardZero) * step : wheel.residual
        if whole != 0 {
            wheel.residual -= whole
            set(scale.clamped(value + whole))
        }
        scheduleEditingEnded()
        return true
    }

    private func scheduleEditingEnded() {
        wheel.settle?.cancel()
        guard let onEditingEnded else { return }
        let work = DispatchWorkItem(block: onEditingEnded)
        wheel.settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}

/// Per-pill scroll state that must not trigger redraws.
private final class WheelState {
    var monitor: Any?
    var residual: Double = 0
    var settle: DispatchWorkItem?
}
