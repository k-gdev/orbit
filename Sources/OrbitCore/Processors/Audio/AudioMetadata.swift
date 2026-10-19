import AVFoundation
import Foundation

/// Reading, stripping and editing the tags of an audio file (title, artist, album, cover art).
public enum AudioMetadata {
    /// The tags the editor can change. `read` lists only tags the file has, so the editor adds these blank.
    public static let editableKeys: [MetadataKey] = [.title, .artist, .album]

    private static let identifiers: [MetadataKey: [AVMetadataIdentifier]] = [
        .title: [.commonIdentifierTitle, .iTunesMetadataSongName, .id3MetadataTitleDescription],
        .artist: [.commonIdentifierArtist, .iTunesMetadataArtist, .id3MetadataLeadPerformer],
        .album: [.commonIdentifierAlbumName, .iTunesMetadataAlbum, .id3MetadataAlbumTitle],
    ]
    private static let artworkIdentifiers: [AVMetadataIdentifier] = [.commonIdentifierArtwork, .iTunesMetadataCoverArt]
    private static let ffmpegKeys: [MetadataKey: String] = [.title: "title", .artist: "artist", .album: "album"]
    private static let labels: [MetadataKey: String] = [.title: "Title", .artist: "Artist", .album: "Album"]
    /// Formats that keep their tags on the audio stream rather than on the file.
    private static let streamTaggedFormats: Set<String> = ["ogg", "opus"]
    /// Formats ffmpeg can attach a picture to.
    private static let artworkFormats: Set<String> = ["mp3", "flac"]

    // MARK: Read

    /// The tags the file has, in editor order, plus its duration. With `ffmpeg`, formats AVFoundation
    /// can't read (and files it finds no tags in) are read through ffmpeg too.
    public static func read(_ url: URL, ffmpeg: FFmpeg? = nil) async -> [MetadataField] {
        let asset = AVURLAsset(url: url)
        var values: [MetadataKey: String] = [:]
        var items = (try? await asset.load(.commonMetadata)) ?? []
        items += (try? await asset.load(.metadata)) ?? []
        for key in editableKeys {
            for id in identifiers[key] ?? [] {
                for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: id) {
                    if let text = try? await item.load(.stringValue), !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        values[key] = text
                        break
                    }
                }
                if values[key] != nil { break }
            }
        }
        if values.isEmpty, let ffmpeg { values = await readWithFFmpeg(url, ffmpeg) }

        var fields = editableKeys.compactMap { key in
            values[key].map { MetadataField(key: key, label: labels[key] ?? "", value: $0, editable: true) }
        }
        var seconds = (try? await asset.load(.duration).seconds).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if seconds == nil, let ffmpeg { seconds = try? await ffmpeg.duration(of: url) }
        if let seconds {
            fields.append(MetadataField(key: .duration, label: "Duration", value: durationText(seconds), editable: false))
        }
        return fields
    }

    private static func readWithFFmpeg(_ url: URL, _ ffmpeg: FFmpeg) async -> [MetadataKey: String] {
        let argv = ["-hide_banner", "-nostdin", "-loglevel", "error", "-i", FFmpeg.pathArg(url), "-f", "ffmetadata", "pipe:1"]
        guard let result = try? await ProcessRunner.run(ffmpeg.executable, argv) else { return [:] }
        var found: [String: String] = [:]
        for line in result.stdout.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("[") { break } // stream and chapter sections
            guard let equals = line.firstIndex(of: "="), !line.hasPrefix(";") else { continue }
            let key = line[..<equals].lowercased()
            let value = unescapeFFMetadata(String(line[line.index(after: equals)...]))
            if !value.trimmingCharacters(in: .whitespaces).isEmpty, found[key] == nil { found[key] = value }
        }
        var values: [MetadataKey: String] = [:]
        for (key, name) in ffmpegKeys { if let value = found[name] { values[key] = value } }
        return values
    }

    /// ffmetadata escapes `=`, `;`, `#`, `\` and line breaks with a backslash.
    private static func unescapeFFMetadata(_ text: String) -> String {
        var out = "", escaped = false
        for character in text {
            if escaped { out.append(character); escaped = false } else if character == "\\" { escaped = true } else { out.append(character) }
        }
        return out
    }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The tags of `url` worth writing into a new m4a made from it: all of them except the source's
    /// encoder delay note, which describes the old encoding. nil when there are none.
    static func carriedTags(from url: URL) async -> [AVMetadataItem]? {
        guard let items = try? await AVURLAsset(url: url).load(.metadata) else { return nil }
        let kept = items.filter { !($0.identifier?.rawValue.contains("iTunSMPB") ?? false) }
        return kept.isEmpty ? nil : kept
    }

    // MARK: Strip

    /// Copies the audio to `output` without any tags or cover art. m4a is re-wrapped without re-encoding;
    /// AAC (ADTS) streams are copied with any ID3v2/ID3v1 blocks cut off; everything else goes through
    /// ffmpeg (`-c copy`), except that wav, aiff and flac are rewritten natively when ffmpeg isn't installed.
    public static func strip(_ item: DroppedItem, to output: URL, ffmpeg: FFmpeg?) async throws {
        switch item.formatKey {
        case "m4a":
            try await remuxWithoutTags(item.url, to: output)
        case "aac":
            try strippingID3(try Data(contentsOf: item.url)).write(to: output, options: .withoutOverwriting)
        default:
            if let ffmpeg {
                let seconds = try? await ffmpeg.duration(of: item.url)
                try await ffmpeg.run(inputs: [item.url],
                                     args: ["-map", "0:a", "-map_metadata", "-1", "-c", "copy", "-fflags", "+bitexact"],
                                     output: output, duration: seconds, progress: { _ in })
            } else if AudioTools.lossless.contains(item.formatKey), !MediaSupport.needsFFmpegToRead(item) {
                try rewriteNatively(item.url, to: output)
            } else {
                throw OrbitError.helperMissing(.ffmpeg)
            }
        }
    }

    /// `data` without leading ID3v2 tags (10-byte header, syncsafe size, optional 10-byte footer) or a
    /// trailing 128-byte ID3v1 "TAG" block. ADTS frames themselves carry no metadata.
    static func strippingID3(_ data: Data) -> Data {
        let b = [UInt8](data)
        var start = 0
        while start + 10 <= b.count, b[start] == 0x49, b[start + 1] == 0x44, b[start + 2] == 0x33, // "ID3"
              b[(start + 6)...(start + 9)].allSatisfy({ $0 < 0x80 }) {
            let size = b[(start + 6)...(start + 9)].reduce(0) { $0 << 7 | Int($1) }
            let footer = b[start + 5] & 0x10 != 0 ? 10 : 0
            let next = start + 10 + size + footer
            guard next <= b.count else { break }
            start = next
        }
        var end = b.count
        if end - start >= 128, b[end - 128] == 0x54, b[end - 127] == 0x41, b[end - 126] == 0x47 { end -= 128 } // "TAG"
        return Data(b[start..<end])
    }

    /// Re-wraps the AAC samples of an m4a in a new file with no metadata. (An export session with an empty
    /// `metadata` list keeps the source's tags, so the samples are copied through a reader and a writer.)
    private static func remuxWithoutTags(_ src: URL, to output: URL) async throws {
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw OrbitError.unsupported("Couldn't read \(src.lastPathComponent).")
        }
        let hint = try await track.load(.formatDescriptions).first
        let reader = try AVAssetReader(asset: asset)
        let source = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(source)
        let writer = try AVAssetWriter(outputURL: output, fileType: .m4a)
        let sink = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
        writer.add(sink)
        guard reader.startReading(), writer.startWriting() else {
            throw OrbitError.unsupported(String(describing: writer.error ?? reader.error ?? CocoaError(.fileReadUnknown)))
        }
        writer.startSession(atSourceTime: .zero)
        func abort() { reader.cancelReading(); writer.cancelWriting() }

        while reader.status == .reading {
            if Task.isCancelled { abort(); throw CancellationError() }
            guard sink.isReadyForMoreMediaData else {
                try await Task.sleep(for: .milliseconds(2))
                continue
            }
            guard let sample = source.copyNextSampleBuffer() else { break }
            if !sink.append(sample) { break }
        }
        let failure = reader.error ?? writer.error
        if reader.status == .failed || writer.status == .failed {
            abort()
            throw OrbitError.processFailed(tool: "AVAssetWriter", code: 1, stderr: String(describing: failure))
        }
        sink.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw OrbitError.processFailed(tool: "AVAssetWriter", code: 1, stderr: String(describing: writer.error))
        }
    }

    /// A tagless copy of a wav, aiff or flac file, written in the sample format it already has.
    private static func rewriteNatively(_ src: URL, to output: URL) throws {
        let input = try AVAudioFile(forReading: src)
        let writer = try AVAudioFile(forWriting: output, settings: input.fileFormat.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        try AudioConverter.copy(from: input, to: writer, progress: { _ in })
    }

    // MARK: Edit

    /// Writes a copy of the audio with `edits` applied. Keys are `title`, `artist`, `album` (an empty
    /// value removes the tag) and `artwork` (the path of a JPEG or PNG). Other tags are kept.
    public static func edit(_ item: DroppedItem, edits: [String: String], to output: URL, ffmpeg: FFmpeg?) async throws {
        var tags: [MetadataKey: String] = [:]
        for (key, name) in ffmpegKeys { if let value = edits[name] { tags[key] = value } }
        let artworkPath = edits["artwork"].flatMap { $0.isEmpty ? nil : $0 }
        guard !tags.isEmpty || artworkPath != nil else {
            throw OrbitError.unsupported("There are no metadata changes to save.")
        }
        let artwork = try artworkPath.map { try loadArtwork(URL(fileURLWithPath: $0)) }

        switch item.formatKey {
        case "m4a":
            try await editM4A(item.url, tags: tags, artwork: artwork, to: output)
        case "aac":
            throw OrbitError.unsupported("AAC files can't hold tags. Convert to M4A first.")
        default:
            guard let ffmpeg else { throw OrbitError.helperMissing(.ffmpeg) }
            if artwork != nil, !artworkFormats.contains(item.formatKey) {
                throw OrbitError.unsupported("\(item.formatKey.uppercased()) files can't hold cover art.")
            }
            var inputs = [item.url]
            var args = ["-map", "0:a"]
            if let artwork {
                inputs.append(artwork.url)
                args += ["-map", "1:v", "-disposition:v:0", "attached_pic", "-metadata:s:v", "title=Album cover",
                         "-metadata:s:v", "comment=Cover (front)"]
            } else {
                args += ["-map", "0:v?"]
            }
            args += ["-map_metadata", "0", "-c", "copy"]
            if item.formatKey == "mp3" { args += ["-id3v2_version", "3"] }
            for (key, value) in tags {
                args += ["-metadata", "\(ffmpegKeys[key]!)=\(value)"]
                // Ogg and Opus write the tags already on the audio stream and ignore the file-level ones.
                if streamTaggedFormats.contains(item.formatKey) { args += ["-metadata:s:a:0", "\(ffmpegKeys[key]!)=\(value)"] }
            }
            let seconds = try? await ffmpeg.duration(of: item.url)
            try await ffmpeg.run(inputs: inputs, args: args, output: output, duration: seconds, progress: { _ in })
        }
    }

    private struct Artwork {
        let url: URL
        let data: Data
        let isPNG: Bool
    }

    private static func loadArtwork(_ url: URL) throws -> Artwork {
        guard let data = try? Data(contentsOf: url) else {
            throw OrbitError.unsupported("Couldn't read the cover art image.")
        }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return Artwork(url: url, data: data, isPNG: true) }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return Artwork(url: url, data: data, isPNG: false) }
        throw OrbitError.unsupported("Cover art must be a JPEG or PNG image.")
    }

    private static func editM4A(_ src: URL, tags: [MetadataKey: String], artwork: Artwork?, to output: URL) async throws {
        let asset = AVURLAsset(url: src)
        var items = try await asset.load(.metadata)
        func drop(_ ids: [AVMetadataIdentifier]) {
            let doomed = Set(ids.flatMap { AVMetadataItem.metadataItems(from: items, filteredByIdentifier: $0) }.compactMap(\.identifier))
            items.removeAll { $0.identifier.map(doomed.contains) ?? false }
        }
        func make(_ id: AVMetadataIdentifier, _ value: any NSCopying & NSObjectProtocol, type: CFString) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = id
            item.dataType = type as String
            item.value = value
            return item
        }
        let iTunesIDs: [MetadataKey: AVMetadataIdentifier] = [
            .title: .iTunesMetadataSongName, .artist: .iTunesMetadataArtist, .album: .iTunesMetadataAlbum,
        ]
        for (key, value) in tags {
            drop(identifiers[key] ?? [])
            if !value.isEmpty, let id = iTunesIDs[key] { items.append(make(id, value as NSString, type: kCMMetadataBaseDataType_UTF8)) }
        }
        if let artwork {
            drop(artworkIdentifiers)
            items.append(make(.iTunesMetadataCoverArt, artwork.data as NSData,
                              type: artwork.isPNG ? kCMMetadataBaseDataType_PNG : kCMMetadataBaseDataType_JPEG))
        }
        try await MediaExport.export(asset, preset: AVAssetExportPresetPassthrough, fileType: .m4a, to: output,
                                     metadata: items, progress: { _ in })
    }
}
