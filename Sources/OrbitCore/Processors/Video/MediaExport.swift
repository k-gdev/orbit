import AVFoundation
import Foundation

/// A thin wrapper over `AVAssetExportSession` that works on macOS 14 (status polling; the async
/// `export(to:as:)` API is macOS 15+). Cancelling the task cancels the export.
public enum MediaExport {
    /// Boxes the session and orders start against cancel: `cancelExport()` on a session that has not
    /// started raises `NSInternalInconsistencyException`, and so does starting it afterwards. AVFoundation
    /// documents `status`/`progress` as callable from any thread.
    private final class SessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        private let lock = NSLock()
        private var started = false
        private var cancelled = false

        init(_ session: AVAssetExportSession) { self.session = session }

        /// Starts the export unless a cancel already landed; returns false in that case.
        func start() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if cancelled { return false }
            session.exportAsynchronously {}
            started = true
            return true
        }

        /// Cancels a started export; before the start it only records the cancel so `start()` bails out.
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if started { session.cancelExport() }
        }
    }

    public static func export(
        _ asset: AVAsset, preset: String, fileType: AVFileType, to output: URL,
        videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil,
        timeRange: CMTimeRange? = nil, metadata: [AVMetadataItem]? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw OrbitError.unsupported("Orbit can't export this video.")
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.videoComposition = videoComposition
        session.audioMix = audioMix
        if let timeRange { session.timeRange = timeRange }
        if let metadata { session.metadata = metadata }
        let box = SessionBox(session)

        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            guard box.start() else { throw CancellationError() }
            while true {
                switch box.session.status {
                case .completed:
                    progress(1)
                    return
                case .failed:
                    let message = box.session.error.map { String(describing: $0) } ?? "unknown error"
                    Log.error("Export failed: \(message)")
                    throw OrbitError.processFailed(tool: "AVAssetExportSession", code: 1, stderr: message)
                case .cancelled:
                    throw CancellationError()
                default:
                    progress(Double(box.session.progress))
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}
