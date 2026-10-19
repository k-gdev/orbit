import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Subject cut-out with Vision's foreground instance mask.
public enum BackgroundRemover {
    /// The image with everything but the foreground subjects made transparent, at full size.
    public static func cutout(_ url: URL) throws -> CGImage {
        let image = try ImageFile.loadOriented(url)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            Log.error("Background removal failed: \(error)")
            throw OrbitError.noSubject
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw OrbitError.noSubject
        }
        let buffer = try observation.generateMaskedImage(ofInstances: observation.allInstances, from: handler,
                                                         croppedToInstancesExtent: false)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let result = CIContext().createCGImage(ciImage, from: ciImage.extent, format: .RGBA8, colorSpace: space) else {
            throw OrbitError.unsupported("Orbit couldn't remove the background from this image.")
        }
        return result
    }
}
