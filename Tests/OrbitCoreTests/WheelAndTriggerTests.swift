import Testing
import Foundation
@testable import OrbitCore

private func smp(t: TimeInterval, down: Bool, mods: ModifierSet, cc: Int, files: Bool, at: CGPoint = .zero) -> InputSample {
    InputSample(time: t, buttonDown: down, modifiers: mods, location: at, dragChangeCount: cc, dragHasFiles: files)
}

/// Drives a machine to an active file drag (`kind == nil`) or into the open state for `kind`.
private func opened(_ kind: WheelKind?) -> TriggerStateMachine {
    var m = TriggerStateMachine(bindings: .defaults)
    _ = m.feed(smp(t: 0, down: true, mods: [], cc: 1, files: false))
    _ = m.feed(smp(t: 0.1, down: true, mods: [], cc: 2, files: true))
    guard let kind else { return m }
    let mods: ModifierSet = switch kind {
    case .convert: [.command]
    case .tools: [.option, .command]
    case .actions: [.control]
    }
    _ = m.feed(smp(t: 0.2, down: true, mods: mods, cc: 2, files: true))
    let e = m.feed(smp(t: 0.26, down: true, mods: mods, cc: 2, files: true))
    #expect(e == .open(kind, at: .zero))
    return m
}

private let g = WheelGeometry.standard

@Test func sliceByAngle() { #expect(g.sliceIndex(offset: .init(dx: 0, dy: 100), count: 8) == 0); #expect(g.sliceIndex(offset: .init(dx: 100, dy: 0), count: 8) == 2)
    #expect(g.sliceIndex(offset: .init(dx: 70, dy: 70), count: 8) == 1); #expect(g.sliceIndex(offset: .init(dx: -100, dy: 0), count: 8) == 6)
    #expect(g.sliceIndex(offset: .init(dx: 0, dy: 40), count: 8) == nil); #expect(g.sliceIndex(offset: .init(dx: 0, dy: 229), count: 8) == 0)
    #expect(g.sliceIndex(offset: .init(dx: 0, dy: 231), count: 8) == nil); #expect(g.centerAngle(index: 1, count: 8) == 45) }
@Test func subRing() { let at = { (deg: Double, r: Double) in CGVector(dx: r * sin(deg * .pi / 180), dy: r * cos(deg * .pi / 180)) }
    #expect(g.subRingIndex(offset: at(90, 200), parentIndex: 2, parentCount: 8, childCount: 3) == 1)
    #expect(g.subRingIndex(offset: at(60, 200), parentIndex: 2, parentCount: 8, childCount: 3) == 0)
    #expect(g.subRingIndex(offset: at(140, 200), parentIndex: 2, parentCount: 8, childCount: 3) == nil)
    #expect(g.subRingIndex(offset: at(90, 150), parentIndex: 2, parentCount: 8, childCount: 3) == nil) }
@Test func geometryDerived() { #expect(g.subRingInner == 180); #expect(g.subRingOuter == 262); #expect(g.panelSide == 644) }
@Test func placementClamps() { #expect(WheelPlacement.center(for: .init(x: 10, y: 10), radius: 190, in: .init(x: 0, y: 0, width: 1440, height: 900)) == .init(x: 190, y: 190))
    #expect(WheelPlacement.center(for: .init(x: -5, y: 500), radius: 190, in: .init(x: -1920, y: 0, width: 1920, height: 1080)) == .init(x: -190, y: 500))
    #expect(WheelPlacement.center(for: .init(x: 700, y: 450), radius: 190, in: .init(x: 0, y: 0, width: 1440, height: 900)) == .init(x: 700, y: 450)) }
@Test func keyboard() { var n = WheelKeyboardNavigator(count: 8); #expect(n.handle(.enter) == .none); #expect(n.handle(.right) == .moved(0))
    #expect(n.handle(.left) == .moved(7)); #expect(n.handle(.down) == .moved(0)); #expect(n.handle(.enter) == .apply(0)); #expect(n.handle(.escape) == .close) }
@Test func bindings() { let b = TriggerBindings.defaults; #expect(b.wheel(for: [.shift]) == .convert); #expect(b.wheel(for: [.command]) == .convert)
    #expect(b.wheel(for: [.shift, .option]) == .tools); #expect(b.wheel(for: [.option, .command]) == .tools); #expect(b.wheel(for: [.control]) == .actions)
    #expect(b.wheel(for: [.command, .shift]) == nil); #expect(b.wheel(for: []) == nil) }
@Test func opensAfterSettleOnFileDrag() { var m = TriggerStateMachine(bindings: .defaults)
    #expect(m.feed(smp(t: 0, down: true, mods: [], cc: 1, files: false)) == nil)
    #expect(m.feed(smp(t: 0.1, down: true, mods: [], cc: 2, files: true)) == nil)
    #expect(m.feed(smp(t: 0.2, down: true, mods: [.command], cc: 2, files: true)) == nil)
    #expect(m.feed(smp(t: 0.26, down: true, mods: [.command], cc: 2, files: true, at: .init(x: 5, y: 6))) == .open(.convert, at: .init(x: 5, y: 6))) }
@Test func nonFileDragNeverOpens() { var m = TriggerStateMachine(bindings: .defaults); _ = m.feed(smp(t: 0, down: true, mods: [], cc: 1, files: false))
    #expect(m.feed(smp(t: 0.3, down: true, mods: [.command], cc: 1, files: false)) == nil); #expect(m.feed(smp(t: 0.4, down: true, mods: [.command], cc: 2, files: false)) == nil) }
@Test func keyHeldAtStartIgnoredUntilRepressed() { var m = TriggerStateMachine(bindings: .defaults); _ = m.feed(smp(t: 0, down: true, mods: [.shift], cc: 1, files: false))
    #expect(m.feed(smp(t: 0.3, down: true, mods: [.shift], cc: 2, files: true)) == nil); _ = m.feed(smp(t: 0.4, down: true, mods: [], cc: 2, files: true))
    _ = m.feed(smp(t: 0.5, down: true, mods: [.shift], cc: 2, files: true)); #expect(m.feed(smp(t: 0.56, down: true, mods: [.shift], cc: 2, files: true)) == .open(.convert, at: .zero)) }
@Test func optionCommandTogetherOpensToolsOnce() { var m = opened(nil); _ = m.feed(smp(t: 0.20, down: true, mods: [.command], cc: 2, files: true))
    #expect(m.feed(smp(t: 0.22, down: true, mods: [.option, .command], cc: 2, files: true)) == nil)
    #expect(m.feed(smp(t: 0.28, down: true, mods: [.option, .command], cc: 2, files: true)) == .open(.tools, at: .zero)) }
@Test func switchKeepOpenCloseOnUp() { var m = opened(.convert); _ = m.feed(smp(t: 1, down: true, mods: [.shift, .option], cc: 2, files: true))
    #expect(m.feed(smp(t: 1.06, down: true, mods: [.shift, .option], cc: 2, files: true)) == .switchTo(.tools))
    #expect(m.feed(smp(t: 1.2, down: true, mods: [], cc: 2, files: true)) == nil); #expect(m.feed(smp(t: 1.3, down: false, mods: [], cc: 2, files: true)) == .close) }
@Test func controlOpensActions() { var m = opened(nil)
    #expect(m.feed(smp(t: 0.2, down: true, mods: [.control], cc: 2, files: true)) == nil)
    #expect(m.feed(smp(t: 0.3, down: true, mods: [.control], cc: 2, files: true, at: .init(x: 9, y: 4))) == .open(.actions, at: .init(x: 9, y: 4))) }
@Test func disabledNeverOpens() { var m = opened(nil); m.isEnabled = false
    for (i, mods) in [ModifierSet.control, [.control], [.command], [.command], [.option, .command], [.option, .command]].enumerated() {
        #expect(m.feed(smp(t: 0.2 + Double(i) * 0.1, down: true, mods: mods, cc: 2, files: true)) == nil)
    }
    #expect(m.feed(smp(t: 1.0, down: false, mods: [], cc: 2, files: true)) == nil) }
@Test func noReopenAfterOverlayClosed() { var m = opened(.convert); m.overlayDidClose(); #expect(m.feed(smp(t: 2, down: true, mods: [.command], cc: 2, files: true)) == nil) }
@Test func reopenAllowedAfterNextDrag() { var m = opened(.convert); m.overlayDidClose()
    #expect(m.feed(smp(t: 2, down: false, mods: [], cc: 2, files: true)) == nil)
    _ = m.feed(smp(t: 3, down: true, mods: [], cc: 2, files: false)); _ = m.feed(smp(t: 3.1, down: true, mods: [], cc: 3, files: true))
    _ = m.feed(smp(t: 3.2, down: true, mods: [.control], cc: 3, files: true))
    #expect(m.feed(smp(t: 3.3, down: true, mods: [.control], cc: 3, files: true)) == .open(.actions, at: .zero)) }
@Test func releasingModifiersWhileOpenKeepsOpen() { var m = opened(.convert)
    #expect(m.feed(smp(t: 0.5, down: true, mods: [], cc: 2, files: true)) == nil)
    #expect(m.feed(smp(t: 0.6, down: true, mods: [], cc: 2, files: true)) == nil) }

@Test func bindingsPersistRoundTrip() {
    let name = "orbit-test-\(UUID())"
    let d = UserDefaults(suiteName: name)!
    defer { d.removePersistentDomain(forName: name) }
    let s = SettingsStore(defaults: d)
    #expect(s.bindings == .defaults)
    var b = TriggerBindings.defaults
    b.actions = [[.control, .shift]]
    s.bindings = b
    let r = SettingsStore(defaults: d)
    #expect(r.bindings == b)
    #expect(r.bindings.wheel(for: [.control, .shift]) == .actions)
}
