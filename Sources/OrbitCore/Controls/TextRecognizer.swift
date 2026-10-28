import CoreGraphics
import Foundation
import Vision

/// Grab Text's recognition step: Vision text recognition (accurate, automatic language, language
/// correction) and barcode detection over one captured image, in a single pass. Synchronous and slow
/// (tenths of a second): call it off the main thread.
public enum TextRecognizer {
    public struct Output: Sendable, Equatable {
        /// Recognised lines in reading order.
        public var lines: [String]
        /// Decoded QR code / barcode payloads (empty when none).
        public var payloads: [String]
    }

    public static func recognize(_ image: CGImage) throws -> Output {
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .accurate
        text.usesLanguageCorrection = true
        text.automaticallyDetectsLanguage = true
        let barcodes = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([text, barcodes])

        let lines = (text.results ?? []).compactMap { observation -> RecognizedLine? in
            guard let best = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: best.string, box: observation.boundingBox)
        }
        let payloads = (barcodes.results ?? []).compactMap(\.payloadStringValue).filter { !$0.isEmpty }
        return Output(lines: GrabTextResult.readingOrder(lines), payloads: payloads)
    }
}
