import AVFoundation
import Foundation
@testable import OrbitCore

extension Fixtures {
    /// A 16-bit WAV of a sine wave. `rightSilent` leaves the right channel empty (left is the sine);
    /// extra channels beyond two repeat the sine. The file lands in `dir` (a fresh temp folder by default).
    static func tone(_ name: String, seconds: Double, freq: Double = 440, amplitude: Double,
                     channels: Int = 2, rightSilent: Bool = false, sampleRate: Double = 44_100,
                     in dir: URL? = nil) -> URL {
        let folder = dir ?? tempDir()
        let url = folder.appending(path: name, directoryHint: .notDirectory)
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
            let total = Int(seconds * sampleRate), chunk = 8192
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(chunk)) else {
                preconditionFailure("Fixtures.tone: no buffer")
            }
            var start = 0
            while start < total {
                let n = min(chunk, total - start)
                buffer.frameLength = AVAudioFrameCount(n)
                for c in 0..<channels {
                    let data = buffer.floatChannelData![c]
                    for i in 0..<n {
                        data[i] = (rightSilent && c == 1) ? 0 : Float(amplitude * sin(2 * .pi * freq * Double(start + i) / sampleRate))
                    }
                }
                try file.write(from: buffer)
                start += n
            }
        } catch {
            preconditionFailure("Fixtures.tone \(name): \(error)")
        }
        return url
    }

    /// A 2-second AAC `.m4a` tone (stereo) carrying an iTunes title tag, and an artist tag when given.
    static func m4a(title: String, artist: String? = nil, in dir: URL? = nil) async -> URL {
        let folder = dir ?? tempDir()
        let wav = tone("src-\(UUID().uuidString.prefix(6)).wav", seconds: 2, amplitude: 0.1, in: folder)
        defer { try? FileManager.default.removeItem(at: wav) }
        let out = folder.appending(path: "tagged-\(UUID().uuidString.prefix(6)).m4a", directoryHint: .notDirectory)
        func item(_ id: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let m = AVMutableMetadataItem()
            m.identifier = id
            m.dataType = kCMMetadataBaseDataType_UTF8 as String
            m.value = value as NSString
            return m
        }
        var items = [item(.iTunesMetadataSongName, title)]
        if let artist { items.append(item(.iTunesMetadataArtist, artist)) }
        do {
            try await MediaExport.export(AVURLAsset(url: wav), preset: AVAssetExportPresetAppleM4A, fileType: .m4a,
                                         to: out, metadata: items, progress: { _ in })
        } catch {
            preconditionFailure("Fixtures.m4a: \(error)")
        }
        return out
    }

    /// Every channel of the file as floats (decoded through `AVAudioFile`).
    static func readSamples(_ url: URL) -> [[Float]] {
        do {
            let file = try AVAudioFile(forReading: url)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                preconditionFailure("Fixtures.readSamples: no buffer")
            }
            try file.read(into: buffer)
            return (0..<Int(file.processingFormat.channelCount)).map {
                Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
            }
        } catch {
            preconditionFailure("Fixtures.readSamples \(url.lastPathComponent): \(error)")
        }
    }

    /// A 1x1 PNG, for cover-art tests.
    static func coverPNG(in dir: URL) -> URL {
        let url = dir.appending(path: "cover-\(UUID().uuidString.prefix(6)).png", directoryHint: .notDirectory)
        let base64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg=="
        do { try Data(base64Encoded: base64)!.write(to: url, options: .withoutOverwriting) } catch {
            preconditionFailure("Fixtures.coverPNG: \(error)")
        }
        return url
    }
}
