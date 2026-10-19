import Accelerate
import AVFoundation
import Foundation

/// Sample-level audio work on float `AVAudioPCMBuffer`s (the non-interleaved Float32 format that
/// `AVAudioFile` hands out as its `processingFormat`).
public enum AudioDSP {
    /// Normalize aims for this RMS level…
    public static let normalizeTargetRMSdB = -16.0
    /// …but never lets the peak rise above this one.
    public static let normalizePeakCeilingDB = -1.0
    public static let bleepFrequency = 1_000.0
    public static let bleepPeakDB = -12.0

    /// Running loudness over a stream of buffers, so a long file can be measured chunk by chunk.
    public struct Meter: Sendable {
        private var sumOfSquares = 0.0
        private var samples = 0
        private var peak: Float = 0

        public init() {}

        public mutating func add(_ buffer: AVAudioPCMBuffer) {
            guard let data = buffer.floatChannelData else { return }
            let n = vDSP_Length(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            for c in 0..<channels {
                var squares: Float = 0
                vDSP_svesq(data[c], 1, &squares, n)
                sumOfSquares += Double(squares)
                var top: Float = 0
                vDSP_maxmgv(data[c], 1, &top, n)
                peak = max(peak, top)
            }
            samples += Int(buffer.frameLength) * channels
        }

        /// RMS over every sample of every channel, in dBFS; `-infinity` for silence.
        public var rmsDB: Double {
            guard samples > 0, sumOfSquares > 0 else { return -.infinity }
            return 10 * log10(sumOfSquares / Double(samples))
        }

        /// The largest absolute sample, in dBFS; `-infinity` for silence.
        public var peakDB: Double { peak > 0 ? 20 * log10(Double(peak)) : -.infinity }
    }

    public static func rmsDB(_ buffer: AVAudioPCMBuffer) -> Double {
        var meter = Meter()
        meter.add(buffer)
        return meter.rmsDB
    }

    public static func peakDB(_ buffer: AVAudioPCMBuffer) -> Double {
        var meter = Meter()
        meter.add(buffer)
        return meter.peakDB
    }

    /// The linear gain that brings a file at `rmsDB` to −16 dBFS RMS, reduced if that would push its
    /// `peakDB` above −1 dBFS. Silence (non-finite levels) gets a gain of 1.
    public static func gainToNormalize(rmsDB: Double, peakDB: Double) -> Double {
        guard rmsDB.isFinite, peakDB.isFinite else { return 1 }
        let gainDB = min(normalizeTargetRMSdB - rmsDB, normalizePeakCeilingDB - peakDB)
        return pow(10, gainDB / 20)
    }

    public static func applyGain(_ buffer: AVAudioPCMBuffer, _ gain: Float) {
        guard gain != 1, let data = buffer.floatChannelData else { return }
        var g = gain
        for c in 0..<Int(buffer.format.channelCount) {
            vDSP_vsmul(data[c], 1, &g, data[c], 1, vDSP_Length(buffer.frameLength))
        }
    }

    /// Replaces the given time ranges (seconds from the start of the audio) with a 1 kHz sine at
    /// −12 dBFS peak, on every channel. `startFrame` is the buffer's position in the whole stream,
    /// so a file processed in chunks gets one unbroken tone.
    public static func applyBleep(_ buffer: AVAudioPCMBuffer, ranges: [ClosedRange<Double>],
                                  startFrame: AVAudioFramePosition = 0) {
        guard let data = buffer.floatChannelData else { return }
        let rate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let amplitude = pow(10, bleepPeakDB / 20)
        for range in ranges {
            let first = max(Int((range.lowerBound * rate).rounded()) - Int(startFrame), 0)
            let last = min(Int((range.upperBound * rate).rounded()) - Int(startFrame), frames)
            guard first < last else { continue }
            for i in first..<last {
                let t = Double(Int(startFrame) + i) / rate
                let value = Float(amplitude * sin(2 * .pi * bleepFrequency * t))
                for c in 0..<Int(buffer.format.channelCount) { data[c][i] = value }
            }
        }
    }

    /// Mono is the average of every channel, stereo duplicates a mono signal (or keeps the first two
    /// channels of a wider one) and swap exchanges the first two channels. The result is a new buffer.
    public static func remix(_ buffer: AVAudioPCMBuffer, op: ChannelOp) -> AVAudioPCMBuffer {
        let inChannels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let outChannels: Int
        switch op {
        case .toMono: outChannels = 1
        case .toStereo: outChannels = 2
        case .swap: outChannels = inChannels
        }
        let format = outChannels == inChannels
            ? buffer.format
            : AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                            channels: AVAudioChannelCount(outChannels), interleaved: false)!
        let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(buffer.frameLength, 1))!
        out.frameLength = buffer.frameLength
        guard let src = buffer.floatChannelData, let dst = out.floatChannelData, frames > 0 else { return out }
        let bytes = frames * MemoryLayout<Float>.size
        switch op {
        case .toMono:
            if inChannels == 1 {
                memcpy(dst[0], src[0], bytes)
            } else {
                memcpy(dst[0], src[0], bytes)
                for c in 1..<inChannels { vDSP_vadd(dst[0], 1, src[c], 1, dst[0], 1, vDSP_Length(frames)) }
                var scale = 1 / Float(inChannels)
                vDSP_vsmul(dst[0], 1, &scale, dst[0], 1, vDSP_Length(frames))
            }
        case .toStereo:
            memcpy(dst[0], src[0], bytes)
            memcpy(dst[1], src[inChannels == 1 ? 0 : 1], bytes)
        case .swap:
            for c in 0..<inChannels {
                let from = inChannels >= 2 && c < 2 ? 1 - c : c
                memcpy(dst[c], src[from], bytes)
            }
        }
        return out
    }
}
