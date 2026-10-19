import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// Photo adjustments with a Core Image chain: auto-enhance, exposure, contrast/saturation, warmth,
/// black and white, then flips and quarter turns.
public enum AdjustRenderer {
    public static func render(_ image: CGImage, _ settings: AdjustSettings) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        var ci = CIImage(cgImage: image)
        let extent = ci.extent

        if settings.auto {
            for filter in ci.autoAdjustmentFilters(options: [.redEye: false]) {
                filter.setValue(ci, forKey: kCIInputImageKey)
                ci = filter.outputImage ?? ci
            }
        }
        if settings.exposure != 0 {
            ci = ci.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: settings.exposure])
        }
        if settings.contrast != 1 || settings.saturation != 1 {
            ci = ci.applyingFilter("CIColorControls", parameters: [
                kCIInputContrastKey: settings.contrast,
                kCIInputSaturationKey: settings.saturation,
            ])
        }
        if settings.warmth != 0 {
            // Telling the filter the light was warmer than neutral makes the picture cooler, and vice versa.
            let kelvin = 6500 - settings.warmth * 2000
            ci = ci.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: kelvin, y: 0),
            ])
        }
        if settings.blackAndWhite {
            ci = ci.applyingFilter("CIPhotoEffectMono")
        }

        // Flips, then quarter turns (positive = clockwise), last.
        if settings.flipHorizontal { ci = ci.oriented(.upMirrored) }
        if settings.flipVertical { ci = ci.oriented(.downMirrored) }
        switch ((settings.quarterTurns % 4) + 4) % 4 {
        case 1: ci = ci.oriented(.right)
        case 2: ci = ci.oriented(.down)
        case 3: ci = ci.oriented(.left)
        default: break
        }

        // Filters such as the temperature change can leave a soft edge; the output is always the original footprint.
        let output = ci.extent.isInfinite ? extent : ci.extent
        let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
        guard let result = context.createCGImage(ci, from: output, format: .RGBA8, colorSpace: space) else {
            throw OrbitError.unsupported("Orbit couldn't adjust this image.")
        }
        return result
    }
}
