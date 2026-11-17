import Foundation

/// A page of the Settings window's side rail.
public enum SettingsPage: Hashable, Sendable {
    case general, wheel, features, feature(FeatureID), about

    public var title: String {
        switch self {
        case .general: "General"
        case .wheel: "Wheel"
        case .features: "Features"
        case .feature(let id): id.title
        case .about: "About"
        }
    }

    /// The SF Symbol shown in the rail.
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .wheel: "circle.circle"
        case .features: "square.grid.2x2"
        case .feature(let id): id.symbol
        case .about: "info.circle"
        }
    }

    /// The rail, top to bottom: General, Wheel, Features, one page per feature (tab order), About.
    public static var railOrder: [SettingsPage] {
        [.general, .wheel, .features] + FeatureID.allCases.map(SettingsPage.feature) + [.about]
    }

    /// The page's command-line name ("general", "wheel", "features", "about", or a feature's raw value).
    public var argument: String {
        switch self {
        case .general: "general"
        case .wheel: "wheel"
        case .features: "features"
        case .feature(let id): id.rawValue
        case .about: "about"
        }
    }

    /// Parses `argument` (the snapshot CLI's page name).
    public init?(argument: String) {
        switch argument {
        case "general": self = .general
        case "wheel": self = .wheel
        case "features": self = .features
        case "about": self = .about
        default:
            guard let id = FeatureID(rawValue: argument) else { return nil }
            self = .feature(id)
        }
    }
}
