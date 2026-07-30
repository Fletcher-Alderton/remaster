import MobileCoreServices
import UIKit

final class RootViewController: UIViewController, UIDocumentPickerDelegate {
    private enum TrackNavigationDestination {
        case artist
        case album
        case genre
    }

    private let libraryStore = LibraryStore()
    private let appState = AppState()
    private let playbackHistoryStore = PlaybackHistoryStore()
    private lazy var mapper = ScreenMapper(store: libraryStore)
    private lazy var playback: PlaybackControlling = AudioPlaybackEngine(
        trackProvider: { [weak self] trackID in
            self?.libraryStore.track(id: trackID)
        },
        fileURLProvider: { [weak self] trackID in
            self?.libraryStore.audioFileURL(for: trackID)
        },
        historyStore: playbackHistoryStore
    )

    private let tabStrip = TabStripView()
    private let contentView = UIView()
    private let miniPlayer = MiniPlayerView()
    private var activeController: UIViewController?
    private var tabControllers: [LibraryTab: UIViewController] = [:]
    private weak var playerController: PlayerViewController?
    private weak var queueController: QueueViewController?
    private weak var settingsController: SettingsViewController?
    private var renderedQueueTrackIDs: [String] = []
    private var renderedQueueCurrentIndex: Int?
    private var settingsReturnTab: LibraryTab = .albums

    override var prefersStatusBarHidden: Bool { return true }
    override var shouldAutorotate: Bool { return false }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { return .portrait }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.pageBackground
        buildRootView()
        configureData()
        configureActions()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(themeDidChange),
            name: ThemeManager.didChangeNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(rescanFinderMusic),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(releaseInactiveTabControllers),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        InteractionMotion.install(in: view)
        refreshTabStrip()
        selectInitialTab()
    }

    private var visibleTabs: [LibraryTab] {
        return appState.tabConfiguration.enabledTabs
    }

    private func buildRootView() {
        tabStrip.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentView.backgroundColor = DesignSystem.pageBackground
        miniPlayer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tabStrip)
        view.addSubview(contentView)
        view.addSubview(miniPlayer)
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: view.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            contentView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            miniPlayer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 7),
            miniPlayer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -7),
            miniPlayer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -7)
        ])
    }

    private func configureData() {
        libraryStore.bootstrapIfNeeded()
        let validPersistedIDs = appState.queueState.trackIDs.filter { libraryStore.track(id: $0) != nil }
        if !validPersistedIDs.isEmpty {
            playback.setQueue(trackIDs: validPersistedIDs, startingAt: appState.queueState.currentIndex)
            playback.seek(to: appState.queueState.elapsed)
        } else if let first = libraryStore.snapshot().tracks.first {
            playback.setQueue(trackIDs: [first.id], startingAt: 0)
        }
        playback.onStateChange = { [weak self] queue in
            guard let self = self else { return }
            self.appState.updateQueueState(queue)
            self.updatePlaybackViews(queue: queue)
        }
        updatePlaybackViews(queue: playback.queueState)
        refreshImportedLibrary()
    }

    @objc private func rescanFinderMusic() {
        refreshImportedLibrary()
    }

    private func refreshImportedLibrary() {
        libraryStore.indexExistingImportedMusic { [weak self] importedCount in
            guard let self = self else { return }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-playback-smoke-test") {
                let tracks = self.libraryStore.snapshot().tracks
                self.playback.setQueue(trackIDs: tracks.map { $0.id }, startingAt: 0)
                self.playback.play()
            }
            #endif
            guard importedCount > 0 else { return }
            self.invalidateLibraryTabControllers()
            let currentID = self.playback.queueState.currentTrackID
            if currentID == nil || self.libraryStore.track(id: currentID ?? "") == nil,
               let first = self.libraryStore.snapshot().tracks.first {
                self.playback.setQueue(trackIDs: [first.id], startingAt: 0)
            }
            self.open(tab: self.appState.currentTab, direction: nil)
        }
    }

    private func configureActions() {
        tabStrip.onSelectionChanged = { [weak self] index in
            guard let self = self, self.visibleTabs.indices.contains(index) else { return }
            self.open(tab: self.visibleTabs[index], direction: nil)
        }
        miniPlayer.onTogglePlayback = { [weak self] in self?.playback.togglePlayPause() }
        miniPlayer.onOpenPlayer = { [weak self] in self?.openPlayer() }
    }

    @objc private func themeDidChange() {
        let updates = {
            self.view.window?.backgroundColor = DesignSystem.pageBackground
            ThemeApplier.apply(to: self.view)
            if let presented = self.presentedViewController {
                ThemeApplier.apply(to: presented.view)
            }
            self.tabStrip.applyTheme()
            self.miniPlayer.applyTheme()
        }
        UIView.transition(
            with: view,
            duration: InteractionMotion.quick,
            options: [.transitionCrossDissolve, .allowAnimatedContent, .beginFromCurrentState],
            animations: updates
        )
    }

    private func refreshTabStrip() {
        let tabs = visibleTabs
        let selectedIndex = tabs.firstIndex(of: appState.currentTab) ?? 0
        let titles = tabs.map { $0.title }
        if tabStrip.titles == titles {
            tabStrip.setSelectedIndex(selectedIndex, animated: false)
        } else {
            tabStrip.configure(titles: titles, selectedIndex: selectedIndex)
        }
        if appState.currentTab == .settings && !tabs.contains(.settings) {
            tabStrip.clearSelection(animated: false)
        }
    }

    private func selectInitialTab() {
        let initial = visibleTabs.contains(appState.currentTab) ? appState.currentTab : (visibleTabs.first ?? .tracks)
        open(tab: initial, direction: nil)
    }

    private func open(tab: LibraryTab, direction: UIPageViewController.NavigationDirection?) {
        if tab != .settings {
            settingsReturnTab = tab
        }
        appState.currentTab = tab
        refreshTabStrip()
        let controller: UIViewController
        if tab == .settings {
            controller = cachedController(for: tab) { self.makeSettingsController() }
            miniPlayer.isHidden = true
        } else {
            controller = cachedController(for: tab) { self.makeLibraryController(tab: tab) }
            miniPlayer.isHidden = playback.queueState.currentTrackID == nil
        }
        guard activeController !== controller else { return }
        replaceActiveController(with: controller, direction: direction)
    }

    private func cachedController(
        for tab: LibraryTab,
        create: () -> UIViewController
    ) -> UIViewController {
        if let controller = tabControllers[tab] { return controller }
        let controller = create()
        tabControllers[tab] = controller
        return controller
    }

    private func invalidateLibraryTabControllers() {
        for tab in LibraryTab.allCases where tab != .settings {
            tabControllers.removeValue(forKey: tab)
        }
    }

    @objc private func releaseInactiveTabControllers() {
        let active = activeController
        tabControllers = tabControllers.filter { $0.value === active }
    }

    private func replaceActiveController(
        with controller: UIViewController,
        direction: UIPageViewController.NavigationDirection?
    ) {
        let old = activeController
        old?.willMove(toParent: nil)
        if controller.parent === self {
            controller.willMove(toParent: nil)
            controller.view.removeFromSuperview()
            controller.removeFromParent()
        }
        addChild(controller)
        controller.loadViewIfNeeded()
        InteractionMotion.install(in: controller.view)
        controller.view.transform = .identity
        controller.view.alpha = 1
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(controller.view)
        controller.view.pinEdges(to: contentView)
        controller.didMove(toParent: self)
        activeController = controller

        let offset: CGFloat
        if direction == .forward { offset = contentView.bounds.width }
        else if direction == .reverse { offset = -contentView.bounds.width }
        else { offset = 0 }

        if offset == 0 || old == nil {
            old?.view.removeFromSuperview()
            old?.removeFromParent()
            return
        }
        controller.view.transform = CGAffineTransform(translationX: offset, y: 0)
        UIView.animate(
            withDuration: InteractionMotion.navigation,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: {
            controller.view.transform = .identity
            old?.view.transform = CGAffineTransform(translationX: -offset * 0.32, y: 0)
            old?.view.alpha = 0.8
        }, completion: { _ in
            guard old !== self.activeController else { return }
            old?.view.transform = .identity
            old?.view.alpha = 1
            old?.view.removeFromSuperview()
            old?.removeFromParent()
        })
    }

    private func makeLibraryController(tab: LibraryTab) -> UIViewController {
        guard let kind = screenKind(for: tab) else { return UIViewController() }
        let controller = LibraryViewController(kind: kind)
        let index = libraryStore.snapshot()
        switch tab {
        case .tracks:
            controller.tracks = index.tracks.map(mapper.track)
        case .albums:
            controller.albums = index.albums.map { mapper.album($0, index: index) }
        case .artists:
            controller.profiles = index.artists.map { mapper.artist($0, index: index) }
        case .genres:
            controller.profiles = index.genres.map { mapper.genre($0, index: index) }
        case .playlists:
            controller.playlists = index.playlists.map { mapper.playlist($0, index: index) }
        case .settings:
            break
        }
        controller.onTrackListSelected = { [weak self] tracks, selectedIndex in
            guard tracks.indices.contains(selectedIndex) else { return }
            self?.play(tracks: Array(tracks.dropFirst(selectedIndex)), startingAt: 0)
        }
        controller.onTrackNavigationRequested = { [weak self] track in self?.showTrackNavigationMenu(for: track) }
        controller.onSongSwipeAction = { [weak self] track, action in self?.handleSongSwipe(action, track: track) }
        controller.onAlbumSelected = { [weak self] album in self?.showAlbum(album) }
        controller.onAlbumQueueRequested = { [weak self] album in self?.showAlbumQueueMenu(for: album) }
        controller.onProfileSelected = { [weak self] profile in self?.showProfile(profile) }
        controller.onTabSwipe = { [weak self] forward in self?.navigateBySwipe(forward: forward) }
        return controller
    }

    private func makeSettingsController() -> SettingsViewController {
        let controller = SettingsViewController(
            items: settingsItems(),
            lastFMUsername: appState.lastFMUsername,
            appearanceMode: ThemeManager.mode
        )
        settingsController = controller
        controller.onConfigurationChanged = { [weak self] items in
            guard let self = self else { return }
            let enabled = items.filter { $0.isEnabled }.compactMap { LibraryTab(rawValue: $0.id) }
            self.appState.updateTabConfiguration(TabConfiguration(enabledTabs: enabled))
            self.refreshTabStrip()
        }
        controller.onImport = { [weak self] in self?.showDocumentPicker() }
        controller.onLastFMChanged = { [weak self] username in self?.appState.setLastFMUsername(username) }
        controller.onAppearanceChanged = { mode in ThemeManager.mode = mode }
        controller.onDismissSwipe = { [weak self] in
            guard let self = self else { return }
            let fallback = self.visibleTabs.contains(self.settingsReturnTab) ? self.settingsReturnTab : (self.visibleTabs.first ?? .tracks)
            self.open(tab: fallback, direction: .reverse)
        }
        return controller
    }

    private func settingsItems() -> [SettingsTabItem] {
        let enabled = visibleTabs
        let order = enabled + LibraryTab.allCases.filter { !enabled.contains($0) }
        return order.map {
            SettingsTabItem(
                id: $0.rawValue,
                title: $0.title,
                isEnabled: enabled.contains($0),
                note: $0 == .settings ? "Always available by swiping past the last tab." : nil
            )
        }
    }

    private func navigateBySwipe(forward: Bool) {
        if appState.currentTab == .settings {
            if !forward {
                let fallback = visibleTabs.contains(settingsReturnTab) ? settingsReturnTab : (visibleTabs.last ?? .tracks)
                open(tab: fallback, direction: .reverse)
            }
            return
        }
        guard let index = visibleTabs.firstIndex(of: appState.currentTab) else { return }
        if forward {
            if index + 1 < visibleTabs.count {
                open(tab: visibleTabs[index + 1], direction: .forward)
            } else {
                open(tab: .settings, direction: .forward)
            }
        } else if index > 0 {
            open(tab: visibleTabs[index - 1], direction: .reverse)
        }
    }

    private func showAlbum(_ album: ScreenAlbum, from presentingController: UIViewController? = nil) {
        let controller = AlbumDetailViewController(album: album)
        controller.modalPresentationStyle = .fullScreen
        controller.onDismissSwipe = { [weak controller] in
            guard let controller = controller else { return }
            InteractionMotion.dismiss(controller)
        }
        controller.onTrackSelected = { [weak self] track in self?.start(track: track) }
        controller.onTrackNavigationRequested = { [weak self] track in self?.showTrackNavigationMenu(for: track) }
        controller.onSongSwipeAction = { [weak self] track, action in self?.handleSongSwipe(action, track: track) }
        controller.onAlbumQueueRequested = { [weak self] selectedAlbum in
            self?.showAlbumQueueMenu(for: selectedAlbum)
        }
        controller.onArtistSelected = { [weak self, weak controller] artistName in
            guard let self = self else { return }
            let index = self.libraryStore.snapshot()
            guard let artist = index.artists.first(where: { $0.name == artistName }) else { return }
            let profile = self.mapper.artist(artist, index: index)
            self.showProfile(profile, from: controller)
        }
        controller.onPlayAlbum = { [weak self] tracks, shuffle in
            self?.play(tracks: shuffle ? tracks.shuffled() : tracks, startingAt: 0)
        }
        InteractionMotion.present(controller, from: presentingController ?? self)
    }

    private func showProfile(_ profile: ScreenProfile, from presentingController: UIViewController? = nil) {
        let controller = ProfileDetailViewController(profile: profile)
        controller.modalPresentationStyle = .fullScreen
        controller.onDismissSwipe = { [weak controller] in
            guard let controller = controller else { return }
            InteractionMotion.dismiss(controller)
        }
        controller.onAlbumSelected = { [weak self, weak controller] album in
            self?.showAlbum(album, from: controller)
        }
        controller.onAlbumQueueRequested = { [weak self] album in
            self?.showAlbumQueueMenu(for: album)
        }
        InteractionMotion.present(controller, from: presentingController ?? self)
    }

    private func showAlbumQueueMenu(for album: ScreenAlbum) {
        let presenter = topPresentedController()
        let menu = UIAlertController(title: album.title, message: album.artist, preferredStyle: .actionSheet)
        menu.view.accessibilityIdentifier = "albumQueueMenu"
        menu.addAction(UIAlertAction(title: "Play Next", style: .default) { [weak self, weak presenter] _ in
            self?.queue(album: album, action: .playNext, hostView: presenter?.view)
        })
        menu.addAction(UIAlertAction(title: "Add to Queue", style: .default) { [weak self, weak presenter] _ in
            self?.queue(album: album, action: .enqueue, hostView: presenter?.view)
        })
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = menu.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        presenter.present(menu, animated: true)
    }

    private func queue(album: ScreenAlbum, action: AlbumQueueAction, hostView: UIView?) {
        let trackIDs = album.tracks.map { $0.id }
        guard !trackIDs.isEmpty else { return }
        let toastAction: SongSwipeAction
        let message: String
        switch action {
        case .playNext:
            if playback.queueState.currentTrackID == nil {
                playback.setQueue(trackIDs: trackIDs, startingAt: 0)
            } else {
                for trackID in trackIDs.reversed() {
                    playback.playNext(trackID: trackID)
                }
            }
            toastAction = .playNext
            message = "Album Queued Next"
        case .enqueue:
            for trackID in trackIDs {
                playback.enqueue(trackID: trackID)
            }
            toastAction = .enqueue
            message = "Album Added to Queue"
        }
        if let hostView = hostView {
            ConfirmationToast.show(in: hostView, action: toastAction, message: message)
        }
    }

    private func start(track: ScreenTrack) {
        let index = libraryStore.snapshot()
        if let album = index.albums.first(where: { $0.trackIDs.contains(track.id) }),
           let offset = album.trackIDs.firstIndex(of: track.id) {
            playback.setQueue(trackIDs: album.trackIDs, startingAt: offset)
        } else {
            playback.setQueue(trackIDs: [track.id], startingAt: 0)
        }
        playback.play()
        openPlayer()
    }

    private func play(tracks: [ScreenTrack], startingAt index: Int) {
        playback.setQueue(trackIDs: tracks.map { $0.id }, startingAt: index)
        playback.play()
        openPlayer()
    }

    private func openPlayer() {
        guard let state = currentPlayerState() else { return }
        if let presented = presentedViewController {
            InteractionMotion.dismiss(presented) { [weak self] in self?.openPlayer() }
            return
        }
        let controller = PlayerViewController(state: state)
        playerController = controller
        controller.onTogglePlayback = { [weak self] in self?.playback.togglePlayPause() }
        controller.onLike = { [weak self] in
            guard let self = self, let id = self.playback.queueState.currentTrackID else { return false }
            self.appState.toggleLike(trackID: id)
            self.updatePlaybackViews(queue: self.playback.queueState)
            return self.appState.isLiked(trackID: id)
        }
        controller.onSeek = { [weak self] ratio in
            guard let self = self,
                  let id = self.playback.queueState.currentTrackID,
                  let duration = self.libraryStore.track(id: id)?.duration else { return }
            self.playback.seek(to: duration * TimeInterval(ratio))
        }
        controller.onOpenQueue = { [weak self] in self?.openQueue() }
        controller.onSkip = { [weak self] in self?.playback.next() }
        controller.onRewind = { [weak self] in self?.playback.previous() }
        controller.onDismissSwipe = { [weak controller] in
            guard let controller = controller else { return }
            InteractionMotion.dismiss(controller)
        }
        controller.onTrackNavigationRequested = { [weak self] track in self?.showTrackNavigationMenu(for: track) }
        InteractionMotion.present(controller, from: self)
    }

    private func openQueue() {
        let queue = playback.queueState
        let screenTracks = queue.trackIDs.compactMap { libraryStore.track(id: $0) }.map(mapper.track)
        let controller = QueueViewController(tracks: screenTracks, currentIndex: queue.currentIndex)
        queueController = controller
        renderedQueueTrackIDs = queue.trackIDs
        renderedQueueCurrentIndex = queue.currentIndex
        controller.onSelectTrack = { [weak self, weak controller] index in
            guard let self = self, let controller = controller else { return }
            let wasPlaying = self.playback.queueState.isPlaying
            self.playback.setQueue(trackIDs: self.playback.queueState.trackIDs, startingAt: index)
            if wasPlaying { self.playback.play() }
            InteractionMotion.dismiss(controller)
        }
        controller.onClearQueue = { [weak self, weak controller] in
            guard let self = self,
                  let controller = controller,
                  let current = self.playback.queueState.currentTrackID,
                  let currentTrack = self.libraryStore.track(id: current) else { return }
            let wasPlaying = self.playback.queueState.isPlaying
            self.playback.setQueue(trackIDs: [current], startingAt: 0)
            if wasPlaying { self.playback.play() }
            controller.update(tracks: [self.mapper.track(currentTrack)], currentIndex: 0)
        }
        controller.onShuffleQueue = { [weak self, weak controller] in
            guard let self = self, let controller = controller else { return }
            let queue = self.playback.queueState
            guard let current = queue.currentTrackID else { return }
            let upcoming = Array(queue.trackIDs.dropFirst(queue.currentIndex + 1)).shuffled()
            let wasPlaying = queue.isPlaying
            self.playback.setQueue(trackIDs: [current] + upcoming, startingAt: 0)
            if wasPlaying { self.playback.play() }
            let tracks = self.playback.queueState.trackIDs.compactMap { self.libraryStore.track(id: $0) }.map(self.mapper.track)
            controller.update(tracks: tracks, currentIndex: 0)
        }
        controller.onSongSwipeAction = { [weak self] track, action in self?.handleSongSwipe(action, track: track) }
        controller.onTrackNavigationRequested = { [weak self] track in self?.showTrackNavigationMenu(for: track) }
        controller.onDismissSwipe = { [weak controller] in
            guard let controller = controller else { return }
            InteractionMotion.dismiss(controller)
        }
        InteractionMotion.present(controller, from: presentedViewController ?? self)
    }

    private func showTrackNavigationMenu(for track: ScreenTrack) {
        let storedTrack = libraryStore.track(id: track.id)
        let artistName = [storedTrack?.albumArtist, storedTrack?.artist, track.artist]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? "Unknown Artist"
        let albumName = [storedTrack?.albumTitle, track.album]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? "Unknown Album"
        let genreName = [storedTrack?.genre]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? "Unknown"
        let menu = UIAlertController(title: track.title, message: nil, preferredStyle: .actionSheet)
        menu.view.accessibilityIdentifier = "trackNavigationMenu"
        menu.addAction(UIAlertAction(title: "Artist: \(artistName)", style: .default) { [weak self] _ in
            self?.openTrackDestination(.artist, for: track)
        })
        menu.addAction(UIAlertAction(title: "Album: \(albumName)", style: .default) { [weak self] _ in
            self?.openTrackDestination(.album, for: track)
        })
        menu.addAction(UIAlertAction(title: "Genre: \(genreName)", style: .default) { [weak self] _ in
            self?.openTrackDestination(.genre, for: track)
        })
        menu.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        let presenter = topPresentedController()
        if let popover = menu.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX,
                y: presenter.view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        presenter.present(menu, animated: true)
    }

    private func openTrackDestination(_ destination: TrackNavigationDestination, for track: ScreenTrack) {
        let index = libraryStore.snapshot()
        let storedTrack = index.tracks.first(where: { $0.id == track.id })
        let destinationProfile: ScreenProfile?
        let destinationAlbum: ScreenAlbum?

        switch destination {
        case .artist:
            let artistNames = [
                storedTrack?.albumArtist,
                storedTrack?.artist,
                track.artist
            ].compactMap { $0 }.filter { !$0.isEmpty }
            let artist = index.artists.first { candidate in
                artistNames.contains { $0.caseInsensitiveCompare(candidate.name) == .orderedSame }
            }
            destinationProfile = artist.map { mapper.artist($0, index: index) }
            destinationAlbum = nil
        case .album:
            let album = index.albums.first(where: { $0.trackIDs.contains(track.id) })
                ?? index.albums.first(where: {
                    $0.title.caseInsensitiveCompare(storedTrack?.albumTitle ?? track.album) == .orderedSame
                })
            destinationAlbum = album.map { mapper.album($0, index: index) }
            destinationProfile = nil
        case .genre:
            let genreName = storedTrack?.genre ?? "Unknown"
            let genre = index.genres.first {
                $0.name.caseInsensitiveCompare(genreName) == .orderedSame
            }
            destinationProfile = genre.map { mapper.genre($0, index: index) }
            destinationAlbum = nil
        }

        let showDestination = { [weak self] in
            guard let self = self else { return }
            if let album = destinationAlbum {
                self.showAlbum(album)
            } else if let profile = destinationProfile {
                self.showProfile(profile)
            }
        }
        if presentedViewController != nil {
            dismiss(animated: false, completion: showDestination)
        } else {
            showDestination()
        }
    }

    private func topPresentedController() -> UIViewController {
        var controller: UIViewController = self
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func currentPlayerState() -> PlayerScreenState? {
        let queue = playback.queueState
        guard let id = queue.currentTrackID, let track = libraryStore.track(id: id) else { return nil }
        return PlayerScreenState(
            track: mapper.track(track),
            isPlaying: queue.isPlaying,
            isLiked: appState.isLiked(trackID: id),
            elapsed: queue.elapsed,
            duration: track.duration,
            queueCount: max(0, queue.trackIDs.count - queue.currentIndex - 1)
        )
    }

    private func updatePlaybackViews(queue: QueueState) {
        guard let state = currentPlayerState() else {
            miniPlayer.isHidden = true
            return
        }
        let progress = state.duration > 0 ? CGFloat(state.elapsed / state.duration) : 0
        miniPlayer.configure(
            title: state.track.title,
            artist: state.track.artist,
            artwork: state.track.artwork,
            isPlaying: state.isPlaying,
            progress: progress
        )
        if appState.currentTab != .settings {
            miniPlayer.isHidden = false
        }
        playerController?.update(state: state)
        if let queueController = queueController,
           queueController.viewIfLoaded?.window != nil,
           renderedQueueTrackIDs != queue.trackIDs || renderedQueueCurrentIndex != queue.currentIndex {
            let queueTracks = queue.trackIDs.compactMap { libraryStore.track(id: $0) }.map(mapper.track)
            renderedQueueTrackIDs = queue.trackIDs
            renderedQueueCurrentIndex = queue.currentIndex
            queueController.update(tracks: queueTracks, currentIndex: queue.currentIndex)
        }
    }

    private func handleSongSwipe(_ action: SongSwipeAction, track: ScreenTrack) {
        let message: String
        switch action {
        case .enqueue:
            playback.enqueue(trackID: track.id)
            message = "Added to Queue"
        case .playNext:
            playback.playNext(trackID: track.id)
            message = "Playing Next"
        case .toggleLike:
            appState.toggleLike(trackID: track.id)
            message = appState.isLiked(trackID: track.id) ? "Liked" : "Like Removed"
        case .more:
            message = "More Options Coming Soon"
        }
        var hostController: UIViewController = self
        while let presented = hostController.presentedViewController {
            hostController = presented
        }
        guard let host = hostController.view else { return }
        ConfirmationToast.show(in: host, action: action, message: message)
    }

    private func screenKind(for tab: LibraryTab) -> LibraryScreenKind? {
        switch tab {
        case .tracks: return .tracks
        case .albums: return .albums
        case .artists: return .artists
        case .playlists: return .playlists
        case .genres: return .genres
        case .settings: return nil
        }
    }

    private func showDocumentPicker() {
        let documentTypes = [kUTTypeAudio as String]
        let picker = UIDocumentPickerViewController(documentTypes: documentTypes, in: .import)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let supported = urls.filter(libraryStore.supportsImport)
        settingsController?.showImportResult("Importing \(supported.count) file\(supported.count == 1 ? "" : "s")…")
        libraryStore.importTracks(from: supported) { [weak self] result in
            guard let self = self else { return }
            let count = result.importedTracks.count
            let summary = "\(count) file\(count == 1 ? "" : "s") imported"
            self.settingsController?.showImportResult(summary)
            self.invalidateLibraryTabControllers()
            if self.appState.currentTab != .settings {
                self.open(tab: self.appState.currentTab, direction: nil)
            }
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        settingsController?.showImportResult("Import cancelled")
    }
}
