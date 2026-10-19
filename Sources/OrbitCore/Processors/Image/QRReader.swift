import Foundation
import Vision

/// QR codes in an image, through Vision.
public enum QRReader {
    /// The decoded strings of every QR code found, in detection order.
    public static func read(_ url: URL) throws -> [String] {
        let image = try ImageFile.loadOriented(url)
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { !$0.isEmpty }
    }
}
