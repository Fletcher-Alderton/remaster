import Foundation

final class AppState {
    private enum Key {
        static let tabConfiguration = "Music.AppState.tabConfiguration"
        static let likedTrackIDs = "Music.AppState.likedTrackIDs"
        static let queueState = "Music.AppState.queueState"
        static let lastFMUsername = "Music.AppState.lastFMUsername"
    }

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private(set) var tabConfiguration: TabConfiguration
    private(set) var likedTrackIDs: Set<String>
    private(set) var queueState: QueueState
    private(set) var lastFMUsername: String?
    var currentTab: LibraryTab
    var presentedDetailID: String?
    var searchText: String = ""

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.tabConfiguration = AppState.decode(TabConfiguration.self, key: Key.tabConfiguration, defaults: defaults, decoder: decoder) ?? TabConfiguration()
        self.likedTrackIDs = Set(defaults.stringArray(forKey: Key.likedTrackIDs) ?? [])
        self.queueState = AppState.decode(QueueState.self, key: Key.queueState, defaults: defaults, decoder: decoder) ?? QueueState()
        self.lastFMUsername = defaults.string(forKey: Key.lastFMUsername)
        self.currentTab = tabConfiguration.enabledTabs.contains(.albums)
            ? .albums
            : (tabConfiguration.enabledTabs.first ?? .discover)
        if defaults.data(forKey: Key.tabConfiguration) != nil {
            persist(tabConfiguration, key: Key.tabConfiguration)
        }
    }

    func updateTabConfiguration(_ configuration: TabConfiguration) {
        tabConfiguration = TabConfiguration(enabledTabs: configuration.enabledTabs)
        if !tabConfiguration.enabledTabs.contains(currentTab) { currentTab = tabConfiguration.enabledTabs[0] }
        persist(tabConfiguration, key: Key.tabConfiguration)
    }

    func toggleLike(trackID: String) {
        if likedTrackIDs.contains(trackID) { likedTrackIDs.remove(trackID) } else { likedTrackIDs.insert(trackID) }
        defaults.set(Array(likedTrackIDs).sorted(), forKey: Key.likedTrackIDs)
    }

    func isLiked(trackID: String) -> Bool { return likedTrackIDs.contains(trackID) }

    func updateQueueState(_ state: QueueState) {
        queueState = state
        persist(state, key: Key.queueState)
    }

    func setLastFMUsername(_ username: String?) {
        let trimmed = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastFMUsername = trimmed.isEmpty ? nil : trimmed
        defaults.set(lastFMUsername, forKey: Key.lastFMUsername)
    }

    private func persist<T: Encodable>(_ object: T, key: String) {
        guard let data = try? encoder.encode(object) else { return }
        defaults.set(data, forKey: key)
    }

    private static func decode<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults, decoder: JSONDecoder) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
