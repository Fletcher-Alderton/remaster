import XCTest
@testable import Music

final class DataLayerTests: XCTestCase {
    func testFinderVisibleMusicDirectoryUsesDocuments() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LibraryStore(applicationSupportDirectory: root)

        XCTAssertEqual(
            store.importedMusicDirectory.standardizedFileURL,
            root.appendingPathComponent("Documents", isDirectory: true).standardizedFileURL
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.importedMusicDirectory.path))
    }

    func testLegacyImportedMusicMigratesIntoFinderVisibleDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyDirectory = root.appendingPathComponent("ImportedMusic", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyFile = legacyDirectory.appendingPathComponent("legacy.flac")
        try Data([0x66, 0x4C, 0x61, 0x43]).write(to: legacyFile)

        let store = LibraryStore(applicationSupportDirectory: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: store.importedMusicDirectory.appendingPathComponent("legacy.flac").path
            )
        )
    }

    func testAutomaticAppearanceUsesLocalNightHours() {
        XCTAssertTrue(ThemeManager.isNight(hour: 0))
        XCTAssertTrue(ThemeManager.isNight(hour: 6))
        XCTAssertFalse(ThemeManager.isNight(hour: 7))
        XCTAssertFalse(ThemeManager.isNight(hour: 18))
        XCTAssertTrue(ThemeManager.isNight(hour: 19))
        XCTAssertTrue(ThemeManager.isNight(hour: 23))
    }

    func testSongSwipeCellUsesDarkThemeSurfaceAtInitialization() {
        let originalMode = ThemeManager.mode
        defer { ThemeManager.mode = originalMode }
        ThemeManager.mode = .dark

        let cell = SongSwipeActionCell(style: .default, reuseIdentifier: nil)

        XCTAssertEqual(cell.backgroundColor, DesignSystem.pageBackground)
        XCTAssertEqual(cell.contentView.backgroundColor, DesignSystem.pageBackground)
    }

    func testPlayerUsesBrokenHeartWhenRemovingLike() {
        XCTAssertEqual(PlayerViewController.likeConfirmationLabel(isLiked: true), "Added to Likes")
        XCTAssertEqual(PlayerViewController.likeConfirmationLabel(isLiked: false), "Removed from Likes")
    }

    func testAlbumDetailUsesAContinuousScrollingTableHeader() {
        let tracks = (0..<10).map {
            ScreenTrack(
                id: "track-\($0)",
                title: "Track \($0)",
                artist: "Artist",
                album: "Album",
                quality: "FLAC",
                artwork: nil,
                duration: 180
            )
        }
        let album = ScreenAlbum(
            id: "album",
            title: "Album",
            artist: "Artist",
            year: "2026",
            genre: "Electronic",
            quality: "FLAC",
            artwork: nil,
            tracks: tracks
        )
        let controller = AlbumDetailViewController(album: album)
        controller.loadViewIfNeeded()
        let table = controller.view.subviews.compactMap { $0 as? UITableView }.first

        XCTAssertNotNil(table?.tableHeaderView)
        XCTAssertEqual(table?.tableHeaderView?.accessibilityIdentifier, "albumDetail.header")
    }

    func testListLibraryTabsClearTheMiniPlayer() {
        for kind in [LibraryScreenKind.tracks, .artists, .genres] {
            let controller = LibraryViewController(kind: kind)
            controller.loadViewIfNeeded()
            let table = controller.view.subviews.compactMap { $0 as? UITableView }.first
            let requiredClearance = DesignSystem.miniPlayerHeight + 14

            XCTAssertEqual(table?.contentInset.bottom, requiredClearance)
            XCTAssertEqual(table?.scrollIndicatorInsets.bottom, requiredClearance)
        }
    }

    func testTabConfigurationKeepsAtLeastOneUniqueTab() {
        let configuration = TabConfiguration(enabledTabs: [.albums, .albums, .artists])
        XCTAssertEqual(configuration.enabledTabs, [.albums, .artists])
        var onlyTab = TabConfiguration(enabledTabs: [.genres])
        onlyTab.setEnabled(false, for: .genres)
        XCTAssertEqual(onlyTab.enabledTabs, [.genres])
    }

    func testQueueStateReturnsNilForInvalidCurrentIndex() {
        XCTAssertNil(QueueState(trackIDs: ["a"], currentIndex: 2).currentTrackID)
        XCTAssertEqual(QueueState(trackIDs: ["a"], currentIndex: 0).currentTrackID, "a")
    }

    func testStoreSearchAndAlbumDerivation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(applicationSupportDirectory: root)
        let track = Track(sourceFileName: "one.mp3", relativePath: "one.mp3", title: "A Song", artist: "Artist", albumTitle: "Record", albumArtist: "Artist", year: 2024, genre: "Electronic")
        var index = store.snapshot()
        index.tracks = [track]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let fixture = try encoder.encode(index)
        try fixture.write(to: root.appendingPathComponent("LibraryIndex.json"))
        let reloaded = LibraryStore(applicationSupportDirectory: root)
        XCTAssertEqual(reloaded.tracks(matching: "song").map { $0.id }, [track.id])
        XCTAssertEqual(reloaded.snapshot().albums.first?.title, "Record")
    }

    func testPlaybackSimulatorAdvancesAndStopsAtQueueEnd() {
        let simulator = PlaybackSimulator { _ in 10 }
        simulator.setQueue(trackIDs: ["first", "second"], startingAt: 0)
        simulator.seek(to: 10)
        simulator.next()
        XCTAssertEqual(simulator.queueState.currentTrackID, "second")
        simulator.next()
        XCTAssertEqual(simulator.queueState.currentTrackID, "first")
        XCTAssertFalse(simulator.queueState.isPlaying)
    }

    func testPlaybackSimulatorEnqueueAndPlayNextPreserveCurrentTrack() {
        let simulator = PlaybackSimulator { _ in 120 }
        simulator.setQueue(trackIDs: ["current", "last"], startingAt: 0)

        simulator.enqueue(trackID: "queued")
        XCTAssertEqual(simulator.queueState.trackIDs, ["current", "last", "queued"])
        XCTAssertEqual(simulator.queueState.currentTrackID, "current")

        simulator.playNext(trackID: "next")
        XCTAssertEqual(simulator.queueState.trackIDs, ["current", "next", "last", "queued"])
        XCTAssertEqual(simulator.queueState.currentTrackID, "current")
    }

    func testPlaybackSimulatorUsesFallbackForMissingDuration() {
        let simulator = PlaybackSimulator { _ in 0 }
        simulator.setQueue(trackIDs: ["unknown-duration"], startingAt: 0)
        simulator.seek(to: 30)
        XCTAssertEqual(simulator.queueState.elapsed, 30)
    }

    func testPlaybackPreviousRestartsThenMovesToPreviousTrack() {
        let simulator = PlaybackSimulator { _ in 120 }
        simulator.setQueue(trackIDs: ["first", "second"], startingAt: 1)
        simulator.seek(to: 12)

        simulator.previous()
        XCTAssertEqual(simulator.queueState.currentTrackID, "second")
        XCTAssertEqual(simulator.queueState.elapsed, 0)

        simulator.previous()
        XCTAssertEqual(simulator.queueState.currentTrackID, "first")
        XCTAssertEqual(simulator.queueState.elapsed, 0)
    }

    func testDerivedIdentifiersDoNotCollideAfterSanitizingNames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(applicationSupportDirectory: root)
        var index = store.snapshot()
        index.tracks = [
            Track(sourceFileName: "one.mp3", relativePath: "one.mp3", title: "One", artist: "Artist", albumTitle: "A/B", albumArtist: "Artist"),
            Track(sourceFileName: "two.mp3", relativePath: "two.mp3", title: "Two", artist: "Artist", albumTitle: "A-B", albumArtist: "Artist")
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(index).write(to: root.appendingPathComponent("LibraryIndex.json"))

        let albumIDs = LibraryStore(applicationSupportDirectory: root).snapshot().albums.map { $0.id }
        XCTAssertEqual(albumIDs.count, 2)
        XCTAssertEqual(Set(albumIDs).count, 2)
    }

    func testSongSwipeThresholdsResolveAllFourActions() {
        let width: CGFloat = 300
        XCTAssertNil(SongSwipeActionCell.resolvedAction(for: -60, width: width))
        XCTAssertEqual(SongSwipeActionCell.resolvedAction(for: -100, width: width), .enqueue)
        XCTAssertEqual(SongSwipeActionCell.resolvedAction(for: -230, width: width), .playNext)
        XCTAssertEqual(SongSwipeActionCell.resolvedAction(for: 100, width: width), .toggleLike)
        XCTAssertEqual(SongSwipeActionCell.resolvedAction(for: 230, width: width), .more)
    }

    func testAppStatePersistsLikesAndTabOrder() {
        let suiteName = "MusicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(defaults: defaults)
        state.toggleLike(trackID: "one")
        state.updateTabConfiguration(TabConfiguration(enabledTabs: [.genres, .tracks]))
        let reloaded = AppState(defaults: defaults)
        XCTAssertTrue(reloaded.isLiked(trackID: "one"))
        XCTAssertEqual(reloaded.tabConfiguration.enabledTabs, [.genres, .tracks])
    }
}
