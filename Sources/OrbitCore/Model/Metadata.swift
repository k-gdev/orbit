import Foundation

/// The metadata fields Orbit shows for a file.
public enum MetadataKey: String, CaseIterable, Sendable {
    case cameraMake, cameraModel, lens, dateTaken, gpsLatitude, gpsLongitude, serialNumber
    case software, artist, copyright, description, title, album, duration, pixelSize
}

/// One row in the metadata editor.
public struct MetadataField: Hashable, Sendable {
    public let key: MetadataKey
    public let label: String
    public let value: String
    public let editable: Bool

    public init(key: MetadataKey, label: String, value: String, editable: Bool) {
        self.key = key
        self.label = label
        self.value = value
        self.editable = editable
    }
}
