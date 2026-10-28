import CoreAudio
import Foundation
import Testing
@testable import OrbitCore

/// The process tap's IOProc body (`TapRenderer`): tap input to the output device's channels, with the
/// ramped gain and the soft clip past unity. Buffer lists are built here the way the HAL hands them over.
@Suite struct SoundRenderTests {
    /// An `AudioBufferList` of interleaved Float32 buffers, each `channels[i]` wide and `frames` long, filled
    /// by `fill(buffer, channel, frame)`. Freed by `free()`.
    final class Buffers {
        let list: UnsafeMutableAudioBufferListPointer
        private var storage: [UnsafeMutablePointer<Float>] = []

        init(channels: [Int], frames: Int, fill: (Int, Int, Int) -> Float = { _, _, _ in 0 }) {
            list = AudioBufferList.allocate(maximumBuffers: channels.count)
            for (b, k) in channels.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: max(k * frames, 1))
                for f in 0..<frames { for c in 0..<k { data[f * k + c] = fill(b, c, f) } }
                storage.append(data)
                list[b] = AudioBuffer(mNumberChannels: UInt32(k), mDataByteSize: UInt32(k * frames * 4), mData: UnsafeMutableRawPointer(data))
            }
        }

        func sample(buffer: Int, channel: Int, frame: Int) -> Float {
            let k = Int(list[buffer].mNumberChannels)
            return storage[buffer][frame * k + channel]
        }

        func samples(buffer: Int, channel: Int) -> [Float] {
            let k = Int(list[buffer].mNumberChannels)
            let frames = Int(list[buffer].mDataByteSize) / (4 * max(k, 1))
            return (0..<frames).map { sample(buffer: buffer, channel: channel, frame: $0) }
        }

        deinit {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
    }

    private func render(_ input: Buffers?, _ output: Buffers, tap: Range<Int> = 0..<1, gain: Float) -> GainRamp {
        var ramp = GainRamp(gain: gain)
        TapRenderer.render(input: input.map { UnsafePointer($0.list.unsafePointer) }, output: output.list.unsafeMutablePointer,
                           tapBuffers: tap, ramp: &ramp)
        return ramp
    }

    @Test func unityPassesThrough() {
        let input = Buffers(channels: [2], frames: 64) { _, c, f in (c == 0 ? 1 : -1) * Float(f) / 100 }
        let output = Buffers(channels: [2], frames: 64) { _, _, _ in 9 }
        _ = render(input, output, gain: 1)
        #expect(output.samples(buffer: 0, channel: 0) == input.samples(buffer: 0, channel: 0))
        #expect(output.samples(buffer: 0, channel: 1) == input.samples(buffer: 0, channel: 1))
    }

    @Test func rendersGainAndClip() {
        let input = Buffers(channels: [2], frames: 256) { _, c, _ in c == 0 ? 0.8 : -0.8 }
        let output = Buffers(channels: [2], frames: 256)
        _ = render(input, output, gain: 1.5)
        let left = output.samples(buffer: 0, channel: 0), right = output.samples(buffer: 0, channel: 1)
        #expect(left.allSatisfy { $0 > 0.8 && $0 <= 1 })
        #expect(right.allSatisfy { $0 < -0.8 && $0 >= -1 })
        // Attenuation is plain gain, no clipping involved.
        let quiet = Buffers(channels: [2], frames: 16)
        _ = render(input, quiet, gain: 0.25)
        #expect(quiet.samples(buffer: 0, channel: 0).allSatisfy { abs($0 - 0.2) < 1e-6 })
        // A loud boosted peak still never passes full scale.
        let loud = Buffers(channels: [2], frames: 32) { _, _, _ in 0.99 }
        let out = Buffers(channels: [2], frames: 32)
        _ = render(loud, out, gain: 1.5)
        #expect(out.samples(buffer: 0, channel: 0).allSatisfy { $0 <= 1 && $0 > 0.95 })
    }

    @Test func mutedWritesSilence() {
        let input = Buffers(channels: [2], frames: 128) { _, _, _ in 0.5 }
        let output = Buffers(channels: [2], frames: 128) { _, _, _ in 0.7 }
        _ = render(input, output, gain: 0)
        #expect(output.samples(buffer: 0, channel: 0).allSatisfy { $0 == 0 })
        #expect(output.samples(buffer: 0, channel: 1).allSatisfy { $0 == 0 })
        // No tap input at all (stream not delivered): silence, not stale data.
        let stale = Buffers(channels: [2], frames: 32) { _, _, _ in 0.7 }
        _ = render(nil, stale, gain: 1)
        #expect(stale.samples(buffer: 0, channel: 0).allSatisfy { $0 == 0 })
    }

    /// The ramp carries across callbacks: a change of volume glides instead of stepping.
    @Test func gainRampsAcrossTheBuffer() {
        let input = Buffers(channels: [2], frames: 480) { _, _, _ in 0.5 }
        let output = Buffers(channels: [2], frames: 480)
        var ramp = GainRamp(gain: 0, rampFrames: 480)
        ramp.target = 1
        TapRenderer.render(input: UnsafePointer(input.list.unsafePointer), output: output.list.unsafeMutablePointer,
                           tapBuffers: 0..<1, ramp: &ramp)
        let left = output.samples(buffer: 0, channel: 0)
        #expect(left.first! < 0.01)
        #expect(left.last! == 0.5)
        #expect(zip(left, left.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(ramp.current == 1)
    }

    /// An aggregate built around a headset also carries the headset's microphone stream: it must never reach
    /// the output, only the tap's stream does.
    @Test func skipsDeviceInputStreams() {
        let input = Buffers(channels: [1, 2], frames: 64) { b, _, _ in b == 0 ? 0.9 : 0.25 }
        let output = Buffers(channels: [2], frames: 64)
        _ = render(input, output, tap: 1..<2, gain: 1)
        #expect(output.samples(buffer: 0, channel: 0).allSatisfy { $0 == 0.25 })
        #expect(output.samples(buffer: 0, channel: 1).allSatisfy { $0 == 0.25 })
        // A tap range past the end of the list is silence, not a crash.
        let none = Buffers(channels: [2], frames: 8) { _, _, _ in 0.3 }
        _ = render(input, none, tap: 5..<6, gain: 1)
        #expect(none.samples(buffer: 0, channel: 0).allSatisfy { $0 == 0 })
    }

    @Test func monoOutputMixesDown() {
        let input = Buffers(channels: [2], frames: 32) { _, c, _ in c == 0 ? 0.6 : 0.2 }
        let output = Buffers(channels: [1], frames: 32)
        _ = render(input, output, gain: 1)
        #expect(output.samples(buffer: 0, channel: 0).allSatisfy { abs($0 - 0.4) < 1e-6 })
    }

    /// Stereo goes to the first two channels of a multichannel output; the rest stay silent.
    @Test func extraOutputChannelsStaySilent() {
        let input = Buffers(channels: [2], frames: 32) { _, c, _ in c == 0 ? 0.6 : 0.2 }
        let output = Buffers(channels: [4], frames: 32) { _, _, _ in 0.9 }
        _ = render(input, output, gain: 1)
        #expect(output.samples(buffer: 0, channel: 0).allSatisfy { $0 == 0.6 })
        #expect(output.samples(buffer: 0, channel: 1).allSatisfy { $0 == 0.2 })
        #expect(output.samples(buffer: 0, channel: 2).allSatisfy { $0 == 0 })
        #expect(output.samples(buffer: 0, channel: 3).allSatisfy { $0 == 0 })
    }

    @Test func nonInterleavedBuffers() {
        let input = Buffers(channels: [1, 1], frames: 32) { b, _, _ in b == 0 ? 0.6 : 0.2 }
        let output = Buffers(channels: [1, 1], frames: 32)
        _ = render(input, output, tap: 0..<2, gain: 1)
        #expect(output.samples(buffer: 0, channel: 0).allSatisfy { $0 == 0.6 })
        #expect(output.samples(buffer: 1, channel: 0).allSatisfy { $0 == 0.2 })
        // A mono tap feeds both sides of a stereo output.
        let mono = Buffers(channels: [1], frames: 16) { _, _, _ in 0.3 }
        let stereo = Buffers(channels: [2], frames: 16)
        _ = render(mono, stereo, gain: 1)
        #expect(stereo.samples(buffer: 0, channel: 1).allSatisfy { $0 == 0.3 })
    }

    /// Which of the aggregate's input buffers are the tap's. Kevo's headset has one 1-channel input stream;
    /// the speakers and the DisplayPort outputs have none. Anything that doesn't add up is refused, so a
    /// microphone stream is never mistaken for the tap.
    @Test func tapStreamLayout() {
        typealias L = TapStreamLayout
        #expect(L.tapBuffers(aggregateInputs: [2], deviceInputs: [], tapChannels: 2) == 0..<1)
        #expect(L.tapBuffers(aggregateInputs: [1, 2], deviceInputs: [1], tapChannels: 2) == 1..<2)
        #expect(L.tapBuffers(aggregateInputs: [2, 1], deviceInputs: [1], tapChannels: 2) == 0..<1)
        #expect(L.tapBuffers(aggregateInputs: [1, 1, 2], deviceInputs: [1, 1], tapChannels: 2) == 2..<3)
        #expect(L.tapBuffers(aggregateInputs: [1, 1], deviceInputs: [], tapChannels: 2) == 0..<2)
        // No tap stream at all, or channel counts that don't match: refuse.
        #expect(L.tapBuffers(aggregateInputs: [1], deviceInputs: [1], tapChannels: 2) == nil)
        #expect(L.tapBuffers(aggregateInputs: [], deviceInputs: [], tapChannels: 2) == nil)
        #expect(L.tapBuffers(aggregateInputs: [1, 4], deviceInputs: [1], tapChannels: 2) == nil)
        #expect(L.tapBuffers(aggregateInputs: [2, 2], deviceInputs: [1], tapChannels: 2) == nil)
        #expect(L.tapBuffers(aggregateInputs: [1], deviceInputs: [1, 1], tapChannels: 2) == nil)
    }

    /// When the output wants more frames than the tap delivered, the rest is silence.
    @Test func shortInputLeavesSilentTail() {
        let input = Buffers(channels: [2], frames: 16) { _, _, _ in 0.5 }
        let output = Buffers(channels: [2], frames: 32) { _, _, _ in 0.9 }
        _ = render(input, output, gain: 1)
        let left = output.samples(buffer: 0, channel: 0)
        #expect(left.prefix(16).allSatisfy { $0 == 0.5 })
        #expect(left.suffix(16).allSatisfy { $0 == 0 })
    }
}
