import XCTest
import UIKit
@testable import Music

/// Album page redesign (requirements ALB-01…ALB-04): compact reference layout,
/// overflow menu, per-track indicators and a single quality summary.
@MainActor
final class AlbumDetailTests: XCTestCase {
    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    private func tracks(_ count: Int = 6, artist: String = "Artist") -> [ScreenTrack] {
        (1...count).map { ScreenTrack(id: "\($0)", title: "Track \($0)", artist: artist, album: "Album", duration: 180) }
    }

    private func album(_ id: String = "album-1", quality: String = "24-bit / 96000 Hz", tracks: [ScreenTrack]? = nil) -> ScreenAlbum {
        ScreenAlbum(id: id, title: "Dance Fish 1 - EP", artist: "Artist", year: "2026", genre: "Dance",
                    quality: quality, tracks: tracks ?? self.tracks())
    }

    private func shown(_ controller: AlbumDetailViewController, size: CGSize = CGSize(width: 320, height: 568)) -> AlbumDetailViewController {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.view.layoutIfNeeded()
        controller.viewDidLayoutSubviews()
        controller.view.layoutIfNeeded()
        self.window = window
        return controller
    }

    private func all(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + all($0) } }
    private func find(_ id: String, in controller: UIViewController) -> UIView? {
        all(controller.view).first { $0.accessibilityIdentifier == id }
    }
    private func action(_ id: AlbumAction.ID, _ controller: AlbumDetailViewController) throws -> AlbumAction {
        try XCTUnwrap(controller.albumActions().first { $0.id == id })
    }

    // MARK: ALB-01 layout

    func testHeaderMatchesCompactReferenceLayoutOnIPodScreen() throws {
        let controller = shown(AlbumDetailViewController(album: album()))
        let table = try XCTUnwrap(all(controller.view).compactMap { $0 as? UITableView }.first)
        let header = try XCTUnwrap(table.tableHeaderView)
        let art = try XCTUnwrap(all(header).compactMap { $0 as? ArtworkView }.first)
        XCTAssertEqual(art.bounds.width, 102, accuracy: 0.5)
        XCTAssertEqual(art.bounds.height, 102, accuracy: 0.5)
        XCTAssertEqual(art.convert(art.bounds, to: controller.view).minX, 20, accuracy: 0.5, "Reference insets artwork 20 pt")

        let play = try XCTUnwrap(find("albumDetail.play", in: controller) as? UIButton)
        let shuffle = try XCTUnwrap(find("albumDetail.shuffle", in: controller) as? UIButton)
        let playFrame = play.convert(play.bounds, to: controller.view)
        let shuffleFrame = shuffle.convert(shuffle.bounds, to: controller.view)
        XCTAssertEqual(playFrame.height, 48, accuracy: 1.5)
        XCTAssertEqual(playFrame.width, shuffleFrame.width, accuracy: 0.5)
        XCTAssertEqual(playFrame.minX, 20, accuracy: 0.5)
        XCTAssertEqual(shuffleFrame.maxX, 300, accuracy: 0.5)
        XCTAssertEqual(play.title(for: .normal), "Play")
        XCTAssertEqual(shuffle.title(for: .normal), "Shuffle")
        XCTAssertNotNil(play.image(for: .normal), "Play needs its glyph, not a text triangle")

        let more = try XCTUnwrap(find("albumDetail.more", in: controller) as? UIButton)
        XCTAssertEqual(more.bounds.width, 28, accuracy: 1)
        XCTAssertEqual(more.accessibilityLabel, "More")
        XCTAssertEqual(more.convert(more.bounds, to: controller.view).maxX, 300, accuracy: 0.5)

        // Compact header: the old 410 pt stack of buttons is gone, so tracks are visible above the fold.
        // Compact header (was 410 pt). The extra quality line makes it slightly taller than the reference.
        XCTAssertLessThanOrEqual(header.bounds.height, 225)
        XCTAssertGreaterThanOrEqual(table.visibleCells.count, 6)
        XCTAssertNil(find("albumDetail.library", in: controller), "Library moved into the overflow menu")
        XCTAssertFalse(header.hasAmbiguousLayout)
        for label in all(header).compactMap({ $0 as? UILabel }) where !label.isHidden && !(label.text ?? "").isEmpty {
            XCTAssertGreaterThanOrEqual(label.bounds.height, label.intrinsicContentSize.height - 0.5,
                                        "'\(label.text ?? "")' is squeezed and clipped")
        }
    }

    func testLongTitlesAndMissingMetadataGrowHeaderWithoutOverlap() throws {
        let long = ScreenAlbum(id: "x", title: String(repeating: "Very Long Album Title ", count: 6), artist: String(repeating: "Several Artists & ", count: 4),
                               year: "", genre: "", quality: "", tracks: tracks(2))
        let controller = shown(AlbumDetailViewController(album: long))
        let title = try XCTUnwrap(find("albumDetail.title", in: controller))
        let more = try XCTUnwrap(find("albumDetail.more", in: controller))
        let play = try XCTUnwrap(find("albumDetail.play", in: controller))
        let titleFrame = title.convert(title.bounds, to: controller.view)
        XCTAssertLessThanOrEqual(titleFrame.maxX, 300.5)
        XCTAssertFalse(titleFrame.intersects(more.convert(more.bounds, to: controller.view)))
        XCTAssertGreaterThan(play.convert(play.bounds, to: controller.view).minY, titleFrame.maxY)
        XCTAssertTrue(find("albumDetail.quality", in: controller)?.isHidden ?? true, "No quality line when Qobuz returned none")
    }

    // MARK: ALB-04 quality

    func testQualityIsShownOnceWithoutRequestedLabel() throws {
        let controller = shown(AlbumDetailViewController(album: album()))
        controller.configureDownloads(manager: nil, tracks: [], quality: .cd)
        let labels = all(controller.view).compactMap { $0 as? UILabel }.compactMap { $0.text }
        XCTAssertEqual((find("albumDetail.quality", in: controller) as? UILabel)?.text, "Hi-Res · 24-bit / 96 kHz")
        XCTAssertEqual(labels.filter { $0.contains("24-bit") }.count, 1)
        XCTAssertFalse(labels.contains { $0.localizedCaseInsensitiveContains("requested") })
        XCTAssertEqual(AlbumDetailViewController.qualitySummary("16-bit / 44100 Hz"), "CD · 16-bit / 44.1 kHz")
        XCTAssertEqual(AlbumDetailViewController.qualitySummary("24-bit / 192000 Hz"), "Hi-Res · 24-bit / 192 kHz")
        XCTAssertEqual(AlbumDetailViewController.qualitySummary("24-bit"), "Hi-Res · 24-bit")
        XCTAssertEqual(AlbumDetailViewController.qualitySummary(""), "")
    }

    // MARK: ALB-02 overflow menu

    func testMenuListsReferenceActionsInOrderWithOnlyPlaylistAsPlaceholder() throws {
        let controller = AlbumDetailViewController(album: album())
        controller.configureLibrary(isSaved: true)
        controller.onLibraryChangeRequested = { _, _, _ in }
        XCTAssertEqual(controller.albumActions().map { $0.id }, [.library, .playlist, .playNext, .playLater, .share, .love, .dislike])
        XCTAssertEqual(try action(.library, controller).title, "Remove…")
        XCTAssertTrue(try action(.library, controller).isDestructive)
        let playlist = try action(.playlist, controller)
        XCTAssertEqual(playlist.title, "Add to a Playlist…")
        XCTAssertFalse(playlist.isEnabled)
        XCTAssertEqual(playlist.detail, "Coming soon")
        // No verified Qobuz preference API yet: visibly unavailable, never a fake success.
        for id in [AlbumAction.ID.love, .dislike] {
            XCTAssertFalse(try action(id, controller).isEnabled)
            XCTAssertEqual(try action(id, controller).detail, "Unavailable")
        }
        XCTAssertTrue(try action(.share, controller).isEnabled)
    }

    func testPlayNextAndPlayLaterQueueTheAlbum() throws {
        let controller = AlbumDetailViewController(album: album())
        var queued: [(String, AlbumQueueAction)] = []
        controller.onQueueAction = { album, action in queued.append((album.id, action)) }
        try action(.playNext, controller).perform()
        try action(.playLater, controller).perform()
        XCTAssertEqual(queued.map { $0.0 }, ["album-1", "album-1"])
        XCTAssertEqual(queued.map { $0.1 }, [.playNext, .enqueue])
    }

    func testShareUsesCanonicalNonSecretQobuzLink() {
        XCTAssertEqual(AlbumDetailViewController.shareURL(for: album("0060254778412"))?.absoluteString,
                       "https://open.qobuz.com/album/0060254778412")
        XCTAssertNil(AlbumDetailViewController.shareURL(for: album("")))
    }

    func testAddingToLibraryWaitsForMutationSuccess() throws {
        let controller = AlbumDetailViewController(album: album())
        XCTAssertFalse(try action(.library, controller).isEnabled, "Unknown save state is never guessed")
        controller.configureLibrary(isSaved: false)
        var completion: ((Result<Void, Error>) -> Void)?
        controller.onLibraryChangeRequested = { id, saved, callback in
            XCTAssertEqual(id, "album-1"); XCTAssertTrue(saved); completion = callback
        }
        XCTAssertEqual(try action(.library, controller).title, "Add to Library")
        try action(.library, controller).perform()
        XCTAssertEqual(try action(.library, controller).title, "Adding…")
        XCTAssertFalse(try action(.library, controller).isEnabled)
        try XCTUnwrap(completion)(.success(()))
        XCTAssertEqual(try action(.library, controller).title, "Remove…")
    }

    func testRemovalAsksForConfirmationAndFailureKeepsSavedState() throws {
        let controller = shown(AlbumDetailViewController(album: album()))
        controller.configureLibrary(isSaved: true)
        var confirmations: [String] = []
        var confirmed: (() -> Void)?
        controller.confirm = { title, _, action in confirmations.append(title); confirmed = action }
        var requests = 0
        var completion: ((Result<Void, Error>) -> Void)?
        controller.onLibraryChangeRequested = { _, saved, callback in XCTAssertFalse(saved); requests += 1; completion = callback }
        try action(.library, controller).perform()
        XCTAssertEqual(requests, 0, "Nothing changes until the removal is confirmed")
        XCTAssertEqual(confirmations.count, 1)
        try XCTUnwrap(confirmed)()
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(try action(.library, controller).title, "Removing…")
        try XCTUnwrap(completion)(.failure(NSError(domain: "test", code: 1)))
        XCTAssertEqual(try action(.library, controller).title, "Remove…")
        XCTAssertEqual((find("albumDetail.status", in: controller) as? UILabel)?.text, "Could not update library. Try again.")
        XCTAssertFalse(find("albumDetail.status", in: controller)?.isHidden ?? true)
    }

    func testOldAlbumCompletionCannotChangeReplacementAlbum() throws {
        let controller = AlbumDetailViewController(album: album())
        controller.configureLibrary(isSaved: false)
        var completion: ((Result<Void, Error>) -> Void)?
        controller.onLibraryChangeRequested = { _, _, callback in completion = callback }
        try action(.library, controller).perform()
        controller.album = album("album-2")
        controller.configureLibrary(isSaved: false)
        try XCTUnwrap(completion)(.success(()))
        XCTAssertEqual(try action(.library, controller).title, "Add to Library")
        XCTAssertTrue(try action(.library, controller).isEnabled)
    }

    func testActionSheetRendersPreviewRowsAndCancelHasNoSideEffect() throws {
        let controller = AlbumDetailViewController(album: album())
        controller.configureLibrary(isSaved: false)
        var queued = 0
        controller.onQueueAction = { _, _ in queued += 1 }
        let sheet = AlbumActionSheetController(album: controller.album, actions: controller.albumActions())
        _ = shown(controller)
        sheet.loadViewIfNeeded()
        sheet.view.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        sheet.view.layoutIfNeeded()
        func row(_ id: String) -> UIView? { all(sheet.view).first { $0.accessibilityIdentifier == id } }
        XCTAssertNotNil(row("albumMenu.preview"))
        for id in ["library", "playlist", "playNext", "playLater", "share", "love", "dislike", "cancel"] {
            let view = try XCTUnwrap(row("albumMenu.\(id)"), id)
            XCTAssertLessThanOrEqual(view.convert(view.bounds, to: sheet.view).maxY, 568, "\(id) must fit on the iPod screen")
        }
        let love = try XCTUnwrap(row("albumMenu.love")).convert(try XCTUnwrap(row("albumMenu.love")).bounds, to: sheet.view)
        let dislike = try XCTUnwrap(row("albumMenu.dislike")).convert(try XCTUnwrap(row("albumMenu.dislike")).bounds, to: sheet.view)
        XCTAssertEqual(love.minY, dislike.minY, accuracy: 0.5, "Love and Dislike share one row")
        for id in ["library", "playNext", "playLater", "share"] {
            let height = try XCTUnwrap(row("albumMenu.\(id)")).bounds.height
            XCTAssertLessThanOrEqual(height, 56, "\(id) row must not stretch to fill spare space")
        }
        XCTAssertFalse((row("albumMenu.playlist") as? UIControl)?.isEnabled ?? true)
        (row("albumMenu.cancel") as? UIControl)?.sendActions(for: .touchUpInside)
        XCTAssertEqual(queued, 0)
    }

    // MARK: ALB-03 track indicators

    func testTrackRowsShowSavedStarAndDownloadIconInsteadOfCounter() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = try QobuzDownloadManager(directory: directory, session: URLSession(configuration: .ephemeral), maximumConcurrentDownloads: 1)
        manager.setAccount(id: 5, resolver: NoopResolver())
        let searchTracks = try [1, 2, 3].map { id in
            try JSONDecoder().decode(QobuzSearchTrack.self, from: Data("{\"id\":\(id),\"title\":\"Track \(id)\",\"duration\":180}".utf8))
        }
        try manager.downloadAlbum(tracks: [searchTracks[1]], quality: .cd)
        let controller = shown(AlbumDetailViewController(album: album(tracks: tracks(3))))
        controller.configureDownloads(manager: manager, tracks: searchTracks, quality: .cd)
        controller.configureSavedTracks(["2"])
        let table = try XCTUnwrap(all(controller.view).compactMap { $0 as? UITableView }.first)
        func cell(_ row: Int) throws -> UITableViewCell { try XCTUnwrap(table.cellForRow(at: IndexPath(row: row, section: 0))) }
        func indicator(_ id: String, _ row: Int) throws -> UIView { try XCTUnwrap(all(try cell(row)).first { $0.accessibilityIdentifier == id }) }
        XCTAssertTrue(try indicator("albumTrack.saved", 0).isHidden)
        XCTAssertFalse(try indicator("albumTrack.saved", 1).isHidden)
        XCTAssertTrue(try indicator("albumTrack.download", 0).isHidden)
        XCTAssertFalse(try indicator("albumTrack.download", 1).isHidden)
        XCTAssertNotNil(try indicator("albumTrack.download", 1).accessibilityLabel, "State is announced, not just colored")
        let text = all(controller.view).compactMap { ($0 as? UILabel)?.text }
        XCTAssertFalse(text.contains { $0.contains("downloaded") && $0.contains("/") }, "No downloaded-track counter")
    }

    func testPerformerSubtitleOnlyWhenItDiffersFromAlbumArtist() throws {
        var rows = tracks(2)
        rows[1] = ScreenTrack(id: "2", title: "Feature", artist: "Guest", album: "Album")
        let controller = shown(AlbumDetailViewController(album: album(tracks: rows)))
        let table = try XCTUnwrap(all(controller.view).compactMap { $0 as? UITableView }.first)
        func subtitle(_ row: Int) -> UIView? {
            table.cellForRow(at: IndexPath(row: row, section: 0)).flatMap { cell in all(cell).first { $0.accessibilityIdentifier == "albumTrack.subtitle" } }
        }
        XCTAssertTrue(subtitle(0)?.isHidden ?? true)
        XCTAssertFalse(subtitle(1)?.isHidden ?? true)
        XCTAssertEqual((subtitle(1) as? UILabel)?.text, "Guest")
    }
}

private final class NoopResolver: QobuzStreamResolving {
    func requestStreamURL(trackID: Int64, quality: QobuzStreamQuality, progress: @escaping (String) -> Void,
                          completion: @escaping (Result<QobuzTrackURL, Error>) -> Void) {}
}

/// Writes iPod-sized renders for visual review against the design references.
/// Skipped unless TEST_RUNNER_ALBUM_SNAPSHOT_DIR is set when running xcodebuild.
@MainActor
final class AlbumPageSnapshotRenders: XCTestCase {
    func testRenderAlbumPageAndMenu() throws {
        guard let directory = ProcessInfo.processInfo.environment["ALBUM_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_ALBUM_SNAPSHOT_DIR to render review screenshots")
        }
        let previousMode = UserDefaults.standard.string(forKey: "appearanceMode")
        defer {
            UserDefaults.standard.set(previousMode, forKey: "appearanceMode")
            ThemeManager.refresh(force: true)
        }
        let artwork = UIGraphicsImageRenderer(size: CGSize(width: 204, height: 204)).image { context in
            let colors = [UIColor(hex: 0x1D6FA3).cgColor, UIColor(hex: 0xF2A65A).cgColor] as CFArray
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
            context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 204, y: 204), options: [])
        }
        let titles = ["Pranha (Flip)", "Long Sadine (Flip)", "Grey Mullet (Flip)", "Chub (Flip)", "Sea Bream (Flip)", "Mackerel (Flip)", "Tide Pool (Flip)", "Late Swim (Flip)"]
        let tracks = titles.enumerated().map { ScreenTrack(id: "\($0.offset + 1)", title: $0.element, artist: $0.offset == 4 ? "OXIS feat. Guest" : "OXIS & torr", album: "Dance Fish 1 - EP") }
        let album = ScreenAlbum(id: "0060254778412", title: "Dance Fish 1 - EP", artist: "OXIS & torr", year: "2026", genre: "Dance",
                                quality: "24-bit / 96000 Hz", artwork: artwork, tracks: tracks)
        for mode in ["light", "dark"] {
            UserDefaults.standard.set(mode, forKey: "appearanceMode")
            ThemeManager.refresh(force: true)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 568))
            let controller = AlbumDetailViewController(album: album)
            controller.configureLibrary(isSaved: true)
            controller.onLibraryChangeRequested = { _, _, _ in }
            controller.onQueueAction = { _, _ in }
            controller.configureSavedTracks(["2"])
            window.rootViewController = controller
            window.makeKeyAndVisible()
            controller.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try save(window, to: "\(directory)/album-\(mode).png")

            let sheet = AlbumActionSheetController(album: album, actions: controller.albumActions(), onPlay: {})
            let presented = expectation(description: "menu \(mode)")
            controller.present(sheet, animated: false) { presented.fulfill() }
            wait(for: [presented], timeout: 2)
            sheet.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            try save(window, to: "\(directory)/menu-\(mode).png")
            controller.dismiss(animated: false)
            window.isHidden = true
        }
    }

    private func save(_ window: UIWindow, to path: String) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: path))
    }
}
