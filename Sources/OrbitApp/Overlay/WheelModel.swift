import AppKit
import Combine
import OrbitCore

/// State of the open wheel: which slices it shows and what the pointer is over.
@MainActor
final class WheelModel: ObservableObject {
    @Published var kind: WheelKind = .convert
    @Published var content = WheelContent(slices: [])
    @Published var items: [DroppedItem] = []
    @Published var highlighted: Int?
    @Published var openSubRing: Int?
    @Published var subHighlighted: Int?
    @Published var thumbnail: NSImage?
    /// Drives the scale-in; `WheelController` animates it to true on show.
    @Published var revealed = false

    let geometry: WheelGeometry
    /// How long the pointer must rest on a slice with children before its sub-ring opens.
    var subRingDelay: Duration = .milliseconds(250)

    private var lastOffset: CGVector?
    private var subRingTimer: Task<Void, Never>?

    init(geometry: WheelGeometry = .standard) {
        self.geometry = geometry
    }

    /// Replaces the wheel's contents and clears any highlight.
    func load(kind: WheelKind, content: WheelContent, items: [DroppedItem]) {
        self.kind = kind
        self.content = content
        self.items = items
        resetPointer()
    }

    func resetPointer() {
        subRingTimer?.cancel()
        subRingTimer = nil
        lastOffset = nil
        highlighted = nil
        openSubRing = nil
        subHighlighted = nil
    }

    /// `offset` is the pointer relative to the wheel centre, `dy` pointing up.
    func updatePointer(offset: CGVector) {
        lastOffset = offset
        let slices = content.slices
        let before = (highlighted, subHighlighted)

        if let parent = openSubRing, slices.indices.contains(parent),
           let child = geometry.subRingIndex(offset: offset, parentIndex: parent, parentCount: slices.count,
                                             childCount: slices[parent].children.count) {
            highlighted = parent
            subHighlighted = child
        } else {
            subHighlighted = nil
            let index = geometry.sliceIndex(offset: offset, count: slices.count)
            if index != highlighted {
                highlighted = index
                openSubRing = nil
                scheduleSubRing(for: index)
            }
        }

        if (highlighted, subHighlighted) != before, highlighted != nil {
            Haptics.tick()
        }
    }

    // MARK: Keyboard-driven selection (no pointer involved)

    /// Highlights slice `index` (nil clears), closing any sub-ring.
    func setHighlight(_ index: Int?) {
        subRingTimer?.cancel()
        subRingTimer = nil
        let changed = index != highlighted || openSubRing != nil || subHighlighted != nil
        highlighted = index
        openSubRing = nil
        subHighlighted = nil
        if changed, index != nil { Haptics.tick() }
    }

    /// Opens the sub-ring of slice `index` and highlights its first child.
    /// Does nothing when the slice has no children.
    func openSubRing(at index: Int) {
        guard content.slices.indices.contains(index), !content.slices[index].children.isEmpty else { return }
        subRingTimer?.cancel()
        subRingTimer = nil
        highlighted = index
        openSubRing = index
        subHighlighted = 0
        Haptics.tick()
    }

    func setSubHighlight(_ index: Int?) {
        guard openSubRing != nil else { return }
        if index != subHighlighted { Haptics.tick() }
        subHighlighted = index
    }

    /// Steps back from the sub-ring to its parent slice, which stays highlighted.
    func closeSubRing() {
        openSubRing = nil
        subHighlighted = nil
    }

    /// The slice a drop would apply: the highlighted child, else a highlighted leaf slice.
    var selectedSlice: Slice? {
        guard let index = highlighted, content.slices.indices.contains(index) else { return nil }
        let slice = content.slices[index]
        if let child = subHighlighted, openSubRing == index, slice.children.indices.contains(child) {
            return slice.children[child]
        }
        return slice.children.isEmpty ? slice : nil
    }

    var hubTitle: String {
        if let index = highlighted, content.slices.indices.contains(index) {
            let slice = content.slices[index]
            if let child = subHighlighted, openSubRing == index, slice.children.indices.contains(child) {
                return slice.children[child].title
            }
            return slice.title
        }
        if items.count == 1, let item = items.first { return item.url.lastPathComponent }
        return "\(items.count) files"
    }

    private func scheduleSubRing(for index: Int?) {
        subRingTimer?.cancel()
        subRingTimer = nil
        guard let index, content.slices.indices.contains(index), !content.slices[index].children.isEmpty else { return }
        let delay = subRingDelay
        subRingTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.highlighted == index else { return }
            self.openSubRing = index
            if let offset = self.lastOffset { self.updatePointer(offset: offset) }
        }
    }
}
