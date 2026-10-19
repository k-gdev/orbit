import AppKit
import Quartz

/// Owns the floating file stacks. Each `add` makes one `FloatPanel`; new ones stack below the
/// last, 8 pt apart. Quick Look for a clicked float is driven from here.
@MainActor
final class FloatManager: NSObject, QLPreviewPanelDataSource {
    static let shared = FloatManager()

    static let spacing: CGFloat = 8

    private(set) var panels: [FloatPanel] = []
    private var previewURLs: [URL] = []

    func add(_ urls: [URL], near point: CGPoint) {
        guard !urls.isEmpty else { return }
        let panel = FloatPanel(urls: urls)
        panel.onClose = { [weak self, weak panel] in
            guard let self, let panel else { return }
            self.panels.removeAll { $0 === panel }
        }
        panel.onPreview = { [weak self] urls in self?.preview(urls) }
        panel.setFrameOrigin(origin(for: panel.frame.size, near: point))
        panels.append(panel)
        panel.orderFrontRegardless()
    }

    func closeAll() {
        for panel in panels { panel.close() }
    }

    // MARK: Placement

    private func origin(for size: CGSize, near point: CGPoint) -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: CGPoint
        if let last = panels.last {
            origin = CGPoint(x: last.frame.minX, y: last.frame.minY - Self.spacing - size.height)
            if origin.y < visible.minY { origin = CGPoint(x: last.frame.maxX + Self.spacing, y: visible.maxY - size.height) }
        } else {
            origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return origin
    }

    // MARK: Quick Look

    private func preview(_ urls: [URL]) {
        previewURLs = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewURLs.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { previewURLs[index] as NSURL }
    }
}
