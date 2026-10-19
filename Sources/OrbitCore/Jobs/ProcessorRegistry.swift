import Foundation

/// The processors the app runs jobs with, in routing order (the first that can handle a unit gets it).
public enum ProcessorRegistry {
    public static func standard(capabilities: Capabilities) -> [any Processor] {
        // Each processor task appends its processor here.
        [
            ImageProcessor(),
            VideoProcessor(),
        ]
    }
}
