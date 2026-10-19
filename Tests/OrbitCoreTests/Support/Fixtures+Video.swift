import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import OrbitCore

extension Fixtures {
    /// A small H.264 clip (a bar sweeping across the frame) with an optional 440 Hz AAC track, written with
    /// `AVAssetWriter`. `metadata` keys `make` and `location` become `AVMetadataItem`s. `rotated` stores the
    /// frames sideways with a 90° `preferredTransform`. The file lands in `dir` (a fresh temp folder by default).
    static func video(_ name: String, seconds: Double, w: Int, h: Int, fps: Int = 30, audio: Bool = true,
                      noise: Bool = false, rotated: Bool = false, metadata: [String: String] = [:],
                      in dir: URL? = nil) async -> URL {
        let folder = dir ?? tempDir()
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            let type: AVFileType = url.pathExtension.lowercased() == "mp4" ? .mp4 : .mov
            let writer = try AVAssetWriter(outputURL: url, fileType: type)
            let storedW = rotated ? h : w, storedH = rotated ? w : h
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: storedW, AVVideoHeightKey: storedH,
            ])
            vInput.expectsMediaDataInRealTime = false
            if rotated { vInput.transform = CGAffineTransform(rotationAngle: .pi / 2).translatedBy(x: 0, y: -CGFloat(storedW)) }
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vInput, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: storedW, kCVPixelBufferHeightKey as String: storedH,
            ])
            writer.add(vInput)
            var aInput: AVAssetWriterInput?
            if audio {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100, AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 64000,
                ])
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                aInput = input
            }
            var items: [AVMetadataItem] = []
            if let make = metadata["make"] {
                let item = AVMutableMetadataItem()
                item.identifier = .quickTimeMetadataMake; item.dataType = kCMMetadataBaseDataType_UTF8 as String; item.value = make as NSString
                items.append(item)
            }
            if let location = metadata["location"] {
                let item = AVMutableMetadataItem()
                item.identifier = .quickTimeMetadataLocationISO6709; item.dataType = kCMMetadataBaseDataType_UTF8 as String
                item.value = location as NSString
                items.append(item)
            }
            writer.metadata = items
            guard writer.startWriting() else { preconditionFailure("Fixtures.video: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: .zero)

            let frames = Int(seconds * Double(fps))
            let sampleRate = 44100, chunk = 1024
            let totalSamples = Int(seconds * Double(sampleRate))
            var frame = 0, sampleCursor = 0
            var videoDone = false, audioDone = false
            var rng = SystemRandomNumberGenerator()
            while frame < frames || (aInput != nil && sampleCursor < totalSamples) {
                let vTime = Double(frame) / Double(fps), aTime = Double(sampleCursor) / Double(sampleRate)
                if frame >= frames, !videoDone { vInput.markAsFinished(); videoDone = true }
                if let aInput, sampleCursor >= totalSamples, !audioDone { aInput.markAsFinished(); audioDone = true }
                if videoDone && (aInput == nil || audioDone) { break }
                let videoReady = frame < frames && vInput.isReadyForMoreMediaData && adaptor.pixelBufferPool != nil
                let audioReady = aInput != nil && sampleCursor < totalSamples && aInput!.isReadyForMoreMediaData
                if !videoReady && !audioReady { try? await Task.sleep(for: .milliseconds(2)); continue }
                if videoReady && (!audioReady || vTime <= aTime) {
                    let pool = adaptor.pixelBufferPool!
                    var pb: CVPixelBuffer?
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    guard let buffer = pb else { preconditionFailure("Fixtures.video: no pixel buffer") }
                    CVPixelBufferLockBaseAddress(buffer, [])
                    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                    let stride = CVPixelBufferGetBytesPerRow(buffer)
                    let barX = (frame * storedW / max(frames, 1))
                    for y in 0..<storedH {
                        for x in 0..<storedW {
                            let o = y * stride + x * 4
                            let onBar = x >= barX && x < barX + max(8, storedW / 10)
                            if noise {
                                base[o] = .random(in: 0...255, using: &rng); base[o + 1] = .random(in: 0...255, using: &rng)
                                base[o + 2] = .random(in: 0...255, using: &rng)
                            } else {
                                base[o] = onBar ? 255 : 30; base[o + 1] = onBar ? 255 : 90; base[o + 2] = onBar ? 255 : 200
                            }
                            base[o + 3] = 255
                        }
                    }
                    CVPixelBufferUnlockBaseAddress(buffer, [])
                    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
                    frame += 1
                } else if let aInput {
                    let n = min(chunk, totalSamples - sampleCursor)
                    aInput.append(try sineBuffer(start: sampleCursor, count: n, rate: sampleRate))
                    sampleCursor += n
                }
            }
            await writer.finishWriting()
            guard writer.status == .completed else { preconditionFailure("Fixtures.video: \(String(describing: writer.error))") }
        } catch {
            preconditionFailure("Fixtures.video \(name): \(error)")
        }
        return url
    }

    /// An MKV made by stream-copying a generated 320×240 MOV with ffmpeg. Requires `hasFFmpeg`.
    static func mkv(seconds: Double, in dir: URL? = nil) async -> URL {
        let folder = dir ?? tempDir()
        let mov = await video("src-\(UUID().uuidString.prefix(6)).mov", seconds: seconds, w: 320, h: 240, in: folder)
        defer { try? FileManager.default.removeItem(at: mov) }
        let out = folder.appending(path: "clip.mkv", directoryHint: .notDirectory)
        do {
            try await FFmpeg(executable: ffmpeg!).run(inputs: [mov], args: ["-c", "copy"], output: out, duration: nil, progress: { _ in })
        } catch {
            preconditionFailure("Fixtures.mkv: \(error)")
        }
        return out
    }

    private static func sineBuffer(start: Int, count: Int, rate: Int) throws -> CMSampleBuffer {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(rate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2,
            mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var samples = [Int16](repeating: 0, count: count)
        for i in 0..<count { samples[i] = Int16(sin(2 * .pi * 440 * Double(start + i) / Double(rate)) * 8000) }
        var block: CMBlockBuffer?
        let bytes = count * 2
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0,
                                           blockBufferOut: &block)
        samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
        var sample: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count,
            presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(rate)),
            packetDescriptions: nil, sampleBufferOut: &sample)
        guard let sample else { throw CocoaError(.fileWriteUnknown) }
        return sample
    }
}
