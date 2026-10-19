import Foundation

public func naturalSorted(_ urls: [URL]) -> [URL] {
    urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}
