import CoreAudio
import Foundation

/// Where the tap's audio sits in the input buffer list of a tap's private aggregate device.
public enum TapStreamLayout {
    /// The buffers holding the tap, given the channels per input stream of the aggregate and of its output
    /// device: after the device's own input streams (the usual layout) or before them, as long as the
    /// leftover streams carry exactly `tapChannels` channels. Nil for any other layout, so a microphone
    /// stream is never mistaken for the tap.
    public static func tapBuffers(aggregateInputs: [Int], deviceInputs: [Int], tapChannels: Int) -> Range<Int>? {
        let tapStreams = aggregateInputs.count - deviceInputs.count
        guard tapStreams >= 1 else { return nil }
        if Array(aggregateInputs.prefix(deviceInputs.count)) == deviceInputs,
           aggregateInputs.suffix(tapStreams).reduce(0, +) == tapChannels {
            return deviceInputs.count..<aggregateInputs.count
        }
        if Array(aggregateInputs.suffix(deviceInputs.count)) == deviceInputs,
           aggregateInputs.prefix(tapStreams).reduce(0, +) == tapChannels {
            return 0..<tapStreams
        }
        return nil
    }
}

/// The body of a process tap's IOProc: copies the tap's audio to the output device's channels, applying
/// the app's volume through a `GainRamp` and, while the gain is past unity, `SoftClip`.
///
/// The private aggregate device behind each tap has the destination output as its sub-device, so its
/// input buffer list can also carry that device's own input streams (a headset's microphone). Only the
/// buffers in `tapBuffers` are read; everything else is ignored, so a microphone can never reach the
/// output. Buffers are interleaved Float32 (the HAL's canonical IOProc format); a buffer with no data
/// pointer (a stream turned off with `kAudioDevicePropertyIOProcStreamUsage`) is skipped.
///
/// Stereo goes to the first two output channels (further channels stay silent); a mono output gets the
/// average of left and right; a mono tap feeds both sides. Output frames the tap did not deliver are
/// silent. Real-time safe: no allocation, no locks, no Objective-C.
public enum TapRenderer {
    public static func render(input: UnsafePointer<AudioBufferList>?, output: UnsafeMutablePointer<AudioBufferList>?,
                              tapBuffers: Range<Int>, ramp: inout GainRamp) {
        guard let output else { return }
        let out = UnsafeMutableAudioBufferListPointer(output)
        var outChannels = 0
        var outFrames = 0
        for buffer in out {
            guard let data = buffer.mData else { continue }
            memset(data, 0, Int(buffer.mDataByteSize))
            let k = Int(buffer.mNumberChannels)
            guard k > 0 else { continue }
            outChannels += k
            outFrames = max(outFrames, Int(buffer.mDataByteSize) / (4 * k))
        }
        guard let input, outChannels > 0 else { return }

        // The first two tap channels are left and right.
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var left: (samples: UnsafePointer<Float>, stride: Int)?
        var right: (samples: UnsafePointer<Float>, stride: Int)?
        var inFrames = Int.max
        let lower = max(tapBuffers.lowerBound, 0), upper = min(tapBuffers.upperBound, list.count)
        if lower < upper {
            for index in lower..<upper where right == nil {
                let buffer = list[index]
                let k = Int(buffer.mNumberChannels)
                guard let data = buffer.mData, k > 0 else { continue }
                let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                inFrames = min(inFrames, Int(buffer.mDataByteSize) / (4 * k))
                for channel in 0..<k where right == nil {
                    if left == nil { left = (samples + channel, k) } else { right = (samples + channel, k) }
                }
            }
        }
        guard let l = left else { return }
        let r = right ?? l
        let frames = min(inFrames, outFrames)
        guard frames > 0 else { return }

        let mono = outChannels == 1
        for frame in 0..<frames {
            let gain = ramp.next()
            var sl = l.samples[frame * l.stride] * gain
            var sr = r.samples[frame * r.stride] * gain
            if gain > 1 {
                sl = SoftClip.apply(sl)
                sr = SoftClip.apply(sr)
            }
            let mixed = (sl + sr) * 0.5
            var channel = 0
            for buffer in out {
                let k = Int(buffer.mNumberChannels)
                guard let data = buffer.mData, k > 0 else { continue }
                if frame < Int(buffer.mDataByteSize) / (4 * k) {
                    let samples = data.assumingMemoryBound(to: Float.self)
                    for c in 0..<k {
                        let global = channel + c
                        samples[frame * k + c] = mono ? mixed : (global == 0 ? sl : (global == 1 ? sr : 0))
                    }
                }
                channel += k
            }
        }
    }
}
