nonisolated enum SitePermission: String, Codable, CaseIterable, Sendable {
    case ask, allow, deny

    var label: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Allow"
        case .deny: "Deny"
        }
    }
}

nonisolated enum MediaKind: String, Codable, Sendable {
    case camera, microphone
}

nonisolated struct SiteSettings: Codable, Equatable, Sendable {
    var blocksTrackers = true
    var allowsJavaScript = true
    var camera = SitePermission.ask
    var microphone = SitePermission.ask

    subscript(kind: MediaKind) -> SitePermission {
        get { kind == .camera ? camera : microphone }
        set {
            switch kind {
            case .camera: camera = newValue
            case .microphone: microphone = newValue
            }
        }
    }
}

// The keys site settings shipped with are required. A key added later decodes with decodeIfPresent and a default, so a
// site saved before it existed still loads.
nonisolated extension SiteSettings {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        blocksTrackers = try container.decode(Bool.self, forKey: .blocksTrackers)
        allowsJavaScript = try container.decode(Bool.self, forKey: .allowsJavaScript)
        camera = try container.decodeIfPresent(SitePermission.self, forKey: .camera) ?? .ask
        microphone = try container.decodeIfPresent(SitePermission.self, forKey: .microphone) ?? .ask
    }
}
