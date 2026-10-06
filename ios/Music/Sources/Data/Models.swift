import Foundation

enum LibraryTab: String, Codable, CaseIterable {
    case discover
    case search
    case albums
    case artists
    case settings

    var title: String {
        switch self {
        case .discover: return "Discover"
        case .search: return "Search"
        case .albums: return "Albums"
        case .artists: return "Artists"
        case .settings: return "Settings"
        }
    }
}

struct QueueState: Codable, Equatable {
    var trackIDs: [String]
    var currentIndex: Int
    var elapsed: TimeInterval
    var isPlaying: Bool
    var isShuffled: Bool

    init(trackIDs: [String] = [], currentIndex: Int = 0, elapsed: TimeInterval = 0, isPlaying: Bool = false, isShuffled: Bool = false) {
        self.trackIDs = trackIDs
        self.currentIndex = currentIndex
        self.elapsed = elapsed
        self.isPlaying = isPlaying
        self.isShuffled = isShuffled
    }

    var currentTrackID: String? {
        guard currentIndex >= 0 && currentIndex < trackIDs.count else { return nil }
        return trackIDs[currentIndex]
    }
}


struct TabConfiguration: Codable, Equatable {
    static let maximumTabs = 4
    static let minimumTabs = 1

    var enabledTabs: [LibraryTab]

    private enum CodingKeys: String, CodingKey {
        case enabledTabs
    }

    init(enabledTabs: [LibraryTab] = [.discover, .search, .albums, .artists]) {
        self.enabledTabs = TabConfiguration.normalized(enabledTabs)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawTabs = try container.decodeIfPresent([String].self, forKey: .enabledTabs) ?? []
        self.enabledTabs = TabConfiguration.normalized(rawTabs.compactMap(LibraryTab.init(rawValue:)))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabledTabs.map(\.rawValue), forKey: .enabledTabs)
    }

    static func normalized(_ tabs: [LibraryTab]) -> [LibraryTab] {
        var unique: [LibraryTab] = []
        for tab in tabs where !unique.contains(tab) && unique.count < maximumTabs {
            unique.append(tab)
        }
        if unique.isEmpty { unique = [.discover] }
        return unique
    }

    mutating func setEnabled(_ isEnabled: Bool, for tab: LibraryTab) {
        if isEnabled {
            guard !enabledTabs.contains(tab), enabledTabs.count < TabConfiguration.maximumTabs else { return }
            enabledTabs.append(tab)
        } else {
            guard enabledTabs.count > TabConfiguration.minimumTabs else { return }
            enabledTabs.removeAll { $0 == tab }
        }
    }

    mutating func moveTab(from source: Int, to destination: Int) {
        guard source >= 0, source < enabledTabs.count, destination >= 0, destination < enabledTabs.count, source != destination else { return }
        let tab = enabledTabs.remove(at: source)
        enabledTabs.insert(tab, at: destination)
    }
}
