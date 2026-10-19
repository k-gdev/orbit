import Accelerate
import AVFoundation
import Foundation

/// The outline of a recording for the trim and bleep editors.
public enum Waveform {
    /// The loudest absolute sample (any channel) in each of `buckets` equal slices of the file, 0...1.
    /// The file is read in chunks. AVFoundation must be able to read it: for other formats pass the
    /// proxy that `ProxyMaker` makes.
    public static func peaks(_ url: URL, buckets: Int) async throws -> [Float] {
        guard buckets > 0 else { return [] }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            Log.error("Waveform: can't read \(url.lastPathComponent): \(error)")
            throw OrbitError.unsupported("Couldn't read \(url.lastPathComponent).")
        }
        let total = file.length
        var peaks = [Float](repeating: 0, count: buckets)
        guard total > 0 else { return peaks }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AudioConverter.chunkFrames) else {
            throw OrbitError.unsupported("Couldn't read \(url.lastPathComponent).")
        }
        let channels = Int(file.processingFormat.channelCount)
        let bucketCount = AVAudioFramePosition(buckets)

        while file.framePosition < total {
            try Task.checkCancellation()
            let position = file.framePosition
            try file.read(into: buffer, frameCount: AudioConverter.chunkFrames)
            let frames = Int(buffer.frameLength)
            if frames == 0 { break }
            guard let data = buffer.floatChannelData else { break }
            var offset = 0
            while offset < frames {
                let frame = position + AVAudioFramePosition(offset)
                let bucket = min(Int(frame * bucketCount / total), buckets - 1)
                // The first frame of the next bucket: ceil((bucket + 1) * total / buckets).
                let boundary = (AVAudioFramePosition(bucket + 1) * total + bucketCount - 1) / bucketCount
                let length = max(1, min(frames - offset, Int(boundary - frame)))
                for c in 0..<channels {
                    var top: Float = 0
                    vDSP_maxmgv(data[c] + offset, 1, &top, vDSP_Length(length))
                    peaks[bucket] = max(peaks[bucket], top)
                }
                offset += length
            }
        }
        return peaks.map { min($0, 1) }
    }
}
