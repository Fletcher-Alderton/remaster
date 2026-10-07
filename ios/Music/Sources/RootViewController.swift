import UIKit

final class RootViewController: UIViewController {
    private let appState = AppState()
    private let playbackBackend: PlaybackControlling?
    private var playbackBackendOverride: PlaybackControlling?
    private var qobuzPresentationTracks: [String: ScreenTrack] = [:]
    private var qobuzCatalogAlbumIDByTrackID: [String: String] = [:]
    private var qobuzCatalogAlbumIDs: Set<String> = []
    private var qobuzAlbumTracksByID: [String: [ScreenTrack]] = [:]
    private var qobuzCatalogArtistIDByName: [String: String] = [:]
    // Album headers must navigate to the primary album artist, not a track's
    // performer (which can be a guest or compilation contributor).
    private var qobuzPrimaryArtistByAlbumID: [String: (id: String, name: String)] = [:]
    private var playback: PlaybackControlling? { playbackBackendOverride ?? playbackBackend }
    private var queueState: QueueState { playback?.queueState ?? QueueState() }
    private let injectedPresentationTrackProvider: ((String) -> ScreenTrack?)?

    init(
        playbackBackend: PlaybackControlling? = nil,
        presentationTrackProvider: ((String) -> ScreenTrack?)? = nil
    ) {
        self.playbackBackend = playbackBackend
        self.injectedPresentationTrackProvider = presentationTrackProvider
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private let tabStrip = TabStripView()
    private let contentView = UIView()
    private let miniPlayer = MiniPlayerView()
    private var activeController: UIViewController?
    private var tabControllers: [LibraryTab: UIViewController] = [:]
    private weak var playerController: PlayerViewController?
    private weak var queueController: QueueViewController?

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
        configurePlaybackState()
    }

    private func configurePlaybackState() {
        guard let controller = playback else {
            appState.updateQueueState(QueueState())
            updatePlaybackViews(queue: QueueState())
            return
        }
        if playbackBackendOverride == nil {
            controller.clearQueue()
        }
        appState.updateQueueState(controller.queueState)
        controller.onStateChange = { [weak self] queue in
            guard let self = self else { return }
            self.appState.updateQueueState(queue)
            self.updatePlaybackViews(queue: queue)
        }
        updatePlaybackViews(queue: controller.queueState)
    }

    private func activatePlaybackBackend(_ backend: PlaybackControlling, presentationTrackProvider: @escaping (String) -> ScreenTrack?) {
        playback?.onStateChange = nil
        playbackBackendOverride = backend
        if let qobuzBackend = backend as? QobuzPlaybackController {
            qobuzBackend.onProgress = { [weak self] message in
                guard let root = self else { return }
                DispatchQueue.main.async {
                    guard let playerController = root.playerController,
                          playerController.viewIfLoaded?.window != nil else { return }
                    playerController.showPlaybackStatus(message)
                }
            }
            qobuzBackend.onStreamResolved = { [weak self] trackID, requestedQuality, stream in
                guard let root = self, root.qobuzPresentationTracks[trackID] != nil else { return }
                let actualQuality = QobuzStreamQuality(rawValue: stream.formatID)
                guard actualQuality != nil else {
                    DispatchQueue.main.async {
                        root.playerController?.showPlaybackStatus("Qobuz returned unsupported format \(stream.formatID).")
                    }
                    return
                }
                let format = "\(stream.bitDepth)-bit / \(Int(stream.samplingRate * 1000)) Hz"
                let status: String
                if let actualQuality = actualQuality, actualQuality != requestedQuality {
                    status = "Requested \(requestedQuality.title); Qobuz provided \(actualQuality.title). Playing returned stream (\(format))."
                } else if let actualQuality = actualQuality {
                    status = "Playing \(actualQuality.title) (\(format))."
                } else {
                    status = "Playing Qobuz stream (\(format))."
                }
                DispatchQueue.main.async {
                    guard let current = root.qobuzPresentationTracks[trackID] else { return }
                    root.qobuzPresentationTracks[trackID] = ScreenTrack(
                        id: current.id,
                        title: current.title,
                        artist: current.artist,
                        album: current.album,
                        quality: status,
                        artwork: current.artwork,
                        artworkURL: current.artworkURL,
                        catalogAlbumID: current.catalogAlbumID,
                        catalogArtistID: current.catalogArtistID,
                        duration: current.duration
                    )
                    root.updatePlaybackViews(queue: root.queueState)
                    root.playerController?.showPlaybackStatus(status)
                }
            }
            qobuzBackend.onError = { [weak self] error in
                guard let root = self else { return }
                let alert = UIAlertController(title: "Qobuz Playback Error", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                root.topPresentedController().present(alert, animated: true)
            }
        }
        configurePlaybackState()
    }


    private func configureActions() {
        tabStrip.onSelectionChanged = { [weak self] index in
            guard let self = self, self.visibleTabs.indices.contains(index) else { return }
            self.open(tab: self.visibleTabs[index], direction: nil)
        }
        miniPlayer.onTogglePlayback = { [weak self] in self?.playback?.togglePlayPause() }
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
        let initial = visibleTabs.contains(appState.currentTab) ? appState.currentTab : (visibleTabs.first ?? .discover)
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
            miniPlayer.isHidden = queueState.currentTrackID == nil
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
        switch tab {
        case .discover, .search:
            guard let credentials = QobuzCredentialStore.shared.load() else {
                return QobuzWelcomeViewController(onSignIn: { [weak self] in self?.showQobuzStreamTest(autoStartSignIn: true) })
            }
            let mode: QobuzCatalogViewController.Mode = tab == .discover ? .discover : .search
            let catalog = QobuzCatalogViewController(mode: mode, client: QobuzStreamingClient(credentials: credentials))
            catalog.onTrackSelected = { [weak self] track in
                self?.rememberQobuz(track)
                self?.playQobuz(track: track, quality: QobuzPreferences.quality)
            }
            catalog.onAlbumSelected = { [weak self, weak catalog] album in
                guard let self = self else { return }
                self.qobuzCatalogAlbumIDs.insert(album.id)
                self.showQobuzAlbum(album, credentials: credentials, from: catalog)
            }
            catalog.onArtistSelected = { [weak self, weak catalog] artist in
                guard let self = self else { return }
                self.qobuzCatalogArtistIDByName[artist.name.lowercased()] = artist.id
                self.showQobuzArtist(artist, credentials: credentials, from: catalog)
            }
            catalog.onPlaylistSelected = { [weak self, weak catalog] playlist in
                self?.showQobuzPlaylist(playlist, from: catalog)
            }
            return catalog
        case .albums, .artists, .tracks:
            guard let credentials = QobuzCredentialStore.shared.load() else {
                return QobuzWelcomeViewController(onSignIn: { [weak self] in self?.showQobuzStreamTest(autoStartSignIn: true) })
            }
            let mode: QobuzCatalogViewController.Mode
            switch tab {
            case .albums: mode = .albums
            case .artists: mode = .artists
            default: mode = .tracks
            }
            let catalog = QobuzCatalogViewController(mode: mode, client: QobuzStreamingClient(credentials: credentials))
            catalog.onTrackSelected = { [weak self] track in
                self?.rememberQobuz(track)
                self?.playQobuz(track: track, quality: QobuzPreferences.quality)
            }
            catalog.onAlbumSelected = { [weak self, weak catalog] album in
                guard let self = self else { return }
                self.qobuzCatalogAlbumIDs.insert(album.id)
                self.showQobuzAlbum(album, credentials: credentials, from: catalog)
            }
            catalog.onArtistSelected = { [weak self, weak catalog] artist in
                guard let self = self else { return }
                self.qobuzCatalogArtistIDByName[artist.name.lowercased()] = artist.id
                self.showQobuzArtist(artist, credentials: credentials, from: catalog)
            }
            return catalog

        case .settings:
            return makeSettingsController()
        }
    }

    private func makeSettingsController() -> SettingsViewController {
        let controller = SettingsViewController(
            items: settingsItems(),
            lastFMUsername: appState.lastFMUsername,
            appearanceMode: ThemeManager.mode
        )

        controller.onConfigurationChanged = { [weak self] items in
            guard let self = self else { return }
            let enabled = items.filter { $0.isEnabled }.compactMap { LibraryTab(rawValue: $0.id) }
            self.appState.updateTabConfiguration(TabConfiguration(enabledTabs: enabled))
            self.refreshTabStrip()
        }

        controller.onQobuzAccountAction = { [weak self] in self?.handleQobuzAccountAction() }
        controller.onQualityChanged = { quality in QobuzPreferences.quality = quality }
        controller.onLastFMChanged = { [weak self] username in self?.appState.setLastFMUsername(username) }
        controller.onAppearanceChanged = { mode in ThemeManager.mode = mode }
        controller.onDismissSwipe = { [weak self] in
            guard let self = self else { return }
            let fallback = self.visibleTabs.contains(self.settingsReturnTab) ? self.settingsReturnTab : (self.visibleTabs.first ?? .discover)
            self.open(tab: fallback, direction: .reverse)
        }
        return controller
    }

    private func settingsItems() -> [SettingsTabItem] {
        let enabled = visibleTabs
        return [LibraryTab.discover, .search, .albums, .artists, .tracks].map { tab in
            SettingsTabItem(
                id: tab.rawValue,
                title: tab.title,
                isEnabled: enabled.contains(tab),
                note: nil
            )
        }
    }

    private func navigateBySwipe(forward: Bool) {
        if appState.currentTab == .settings {
            if !forward {
                let fallback = visibleTabs.contains(settingsReturnTab) ? settingsReturnTab : (visibleTabs.last ?? .discover)
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
        qobuzCatalogAlbumIDs.insert(album.id)
        guard let credentials = QobuzCredentialStore.shared.load() else { return }
        showQobuzAlbum(album, credentials: credentials, from: presentingController)
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
        controller.onTrackSelected = { [weak self] track in self?.start(track: track) }
        controller.onTrackNavigationRequested = { [weak self] track in self?.showTrackNavigationMenu(for: track) }
        controller.onSongSwipeAction = { [weak self] track, action in self?.handleSongSwipe(action, track: track) }
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
        guard !album.tracks.isEmpty else {
            guard let credentials = QobuzCredentialStore.shared.load() else { return }
            showQobuzAlbum(album, credentials: credentials, from: topPresentedController())
            return
        }
        album.tracks.forEach(rememberQobuz)
        guard ensureQobuzPlaybackBackend(), let playback = playback else { return }
        let wasEmpty = playback.queueState.currentTrackID == nil
        let message = action == .playNext ? "Album Queued Next" : "Album Added to Queue"
        if wasEmpty {
            playback.setQueue(trackIDs: album.tracks.map(\.id), startingAt: 0)
        } else if action == .playNext {
            for track in album.tracks.reversed() { playback.playNext(trackID: track.id) }
        } else {
            for track in album.tracks { playback.enqueue(trackID: track.id) }
        }
        if wasEmpty {
            playback.play()
            openPlayer()
        }
        if let hostView = hostView {
            ConfirmationToast.show(in: hostView, action: action == .playNext ? .playNext : .enqueue, message: message)
        }
    }

    private func start(track: ScreenTrack) {
        guard qobuzPresentationTracks[track.id] != nil else { return }
        if let albumID = qobuzCatalogAlbumIDByTrackID[track.id],
           let albumTracks = qobuzAlbumTracksByID[albumID],
           let index = albumTracks.firstIndex(where: { $0.id == track.id }) {
            let queue = Array(albumTracks.dropFirst(index))
            playQobuz(tracks: queue, startingAt: 0, quality: QobuzPreferences.quality)
        } else {
            playQobuz(track: track, quality: QobuzPreferences.quality)
        }
    }

    private func play(tracks: [ScreenTrack], startingAt index: Int, preserveBackend: Bool = false) {
        let typedTracks = tracks
        if typedTracks.contains(where: { qobuzPresentationTracks[$0.id] != nil }) {
            guard typedTracks.allSatisfy({ qobuzPresentationTracks[$0.id] != nil }) else {
                showCatalogError(QobuzStreamingError.invalidResponse)
                return
            }
            playQobuz(tracks: typedTracks, startingAt: index, quality: QobuzPreferences.quality)
            return
        }
        guard preserveBackend, let playback = playback else { return }
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
        controller.onTogglePlayback = { [weak self] in self?.playback?.togglePlayPause() }
        controller.onLike = { [weak self] in
            guard let self = self, let id = self.queueState.currentTrackID else { return false }
            self.appState.toggleLike(trackID: id)
            self.updatePlaybackViews(queue: self.queueState)
            return self.appState.isLiked(trackID: id)
        }
        controller.onSeek = { [weak self] ratio in
            guard let self = self,
                  let playback = self.playback,
                  let id = playback.queueState.currentTrackID,
                  let track = self.presentationTrack(id: id) else { return }
            playback.seek(to: track.duration * TimeInterval(ratio))
        }
        controller.onOpenQueue = { [weak self] in self?.openQueue() }
        controller.onSkip = { [weak self] in self?.playback?.next() }
        controller.onRewind = { [weak self] in self?.playback?.previous() }
        controller.onDismissSwipe = { [weak controller] in
            guard let controller = controller else { return }
            InteractionMotion.dismiss(controller)
        }
        controller.onTrackNavigationRequested = { [weak self] track in self?.showTrackNavigationMenu(for: track) }
        InteractionMotion.present(controller, from: self)
    }

    private func openQueue() {
        guard let playback = playback else { return }
        let queue = playback.queueState
        let screenTracks = presentationTracks(for: queue.trackIDs)
        let controller = QueueViewController(tracks: screenTracks, currentIndex: queue.currentIndex)
        queueController = controller
        renderedQueueTrackIDs = queue.trackIDs
        renderedQueueCurrentIndex = queue.currentIndex
        controller.onSelectTrack = { [weak self, weak controller] index in
            guard let self = self, let controller = controller, let playback = self.playback else { return }
            let wasPlaying = playback.queueState.isPlaying
            playback.setQueue(trackIDs: playback.queueState.trackIDs, startingAt: index)
            if wasPlaying { playback.play() }
            InteractionMotion.dismiss(controller)
        }
        controller.onClearQueue = { [weak self, weak controller] in
            guard let self = self,
                  let controller = controller,
                  let playback = self.playback,
                  let current = playback.queueState.currentTrackID,
                  let currentTrack = self.presentationTrack(id: current) else { return }
            let wasPlaying = playback.queueState.isPlaying
            playback.setQueue(trackIDs: [current], startingAt: 0)
            if wasPlaying { playback.play() }
            controller.update(tracks: [currentTrack], currentIndex: 0)
        }
        controller.onShuffleQueue = { [weak self, weak controller] in
            guard let self = self, let controller = controller, let playback = self.playback else { return }
            let queue = playback.queueState
            guard let current = queue.currentTrackID else { return }
            let upcoming = Array(queue.trackIDs.dropFirst(queue.currentIndex + 1)).shuffled()
            let wasPlaying = queue.isPlaying
            playback.setQueue(trackIDs: [current] + upcoming, startingAt: 0)
            if wasPlaying { playback.play() }
            let tracks = self.presentationTracks(for: playback.queueState.trackIDs)
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
        guard qobuzPresentationTracks[track.id] != nil else { return }
        let alert = UIAlertController(title: track.title, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Artist: \(track.artist)", style: .default) { [weak self] _ in
            guard let self = self,
                  let credentials = QobuzCredentialStore.shared.load(),
                  let artistID = self.qobuzCatalogArtistIDByName[track.artist.lowercased()] else { return }
            let currentPresenter = self.topPresentedController()
            self.showQobuzArtist(ScreenProfile(id: artistID, name: track.artist, subtitle: "Qobuz artist", information: "", albums: []), credentials: credentials, from: currentPresenter)
        })
        alert.addAction(UIAlertAction(title: "Album: \(track.album)", style: .default) { [weak self] _ in
            guard let self = self,
                  let credentials = QobuzCredentialStore.shared.load(),
                  let albumID = self.qobuzCatalogAlbumIDByTrackID[track.id] else { return }
            let currentPresenter = self.topPresentedController()
            self.showQobuzAlbum(ScreenAlbum(id: albumID, title: track.album, artist: track.artist, year: ""), credentials: credentials, from: currentPresenter)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let presenter = topPresentedController()
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        presenter.present(alert, animated: true)
    }

    private func topPresentedController() -> UIViewController {
        var controller: UIViewController = self
        while let presented = controller.presentedViewController {
            controller = presented
        }
        return controller
    }

    private func presentationTrack(id: String) -> ScreenTrack? {
        if let track = qobuzPresentationTracks[id] {
            return track
        }
        if let track = injectedPresentationTrackProvider?(id) {
            return track
        }
        return nil
    }

    /// Queue rows are positional: never drop an unresolved ID and shift the displayed
    /// current index or later row actions. Use an explicit unavailable row instead.
    private func presentationTracks(for ids: [String]) -> [ScreenTrack] {
        return ids.map { id in
            presentationTrack(id: id) ?? ScreenTrack(
                id: id,
                title: "Unavailable Track",
                artist: "Unknown Artist",
                album: "Unavailable",
                duration: 0
            )
        }
    }

    private func currentPlayerState() -> PlayerScreenState? {
        let queue = queueState
        guard let id = queue.currentTrackID, let track = presentationTrack(id: id) else { return nil }
        return PlayerScreenState(
            track: track,
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
            let queueTracks = presentationTracks(for: queue.trackIDs)
            renderedQueueTrackIDs = queue.trackIDs
            renderedQueueCurrentIndex = queue.currentIndex
            queueController.update(tracks: queueTracks, currentIndex: queue.currentIndex)
        }
    }

    private func handleSongSwipe(_ action: SongSwipeAction, track: ScreenTrack) {
        let message: String
        switch action {
        case .enqueue:
            guard qobuzPresentationTracks[track.id] != nil else { return }
            rememberQobuz(track)
            guard ensureQobuzPlaybackBackend(), let playback = playback else { return }
            playback.enqueue(trackID: track.id)
            message = "Added to Queue"
        case .playNext:
            guard qobuzPresentationTracks[track.id] != nil else { return }
            rememberQobuz(track)
            guard ensureQobuzPlaybackBackend(), let playback = playback else { return }
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


    private func playQobuz(track: ScreenTrack, quality: QobuzStreamQuality) {
        rememberQobuz(track)
        playQobuz(tracks: [track], startingAt: 0, quality: quality)
    }

    private func playQobuz(tracks: [ScreenTrack], startingAt index: Int, quality: QobuzStreamQuality) {
        guard !tracks.isEmpty,
              let credentials = QobuzCredentialStore.shared.load() else {
            let alert = UIAlertController(title: "Qobuz Sign-In Required", message: "Sign in to your Qobuz account before playing music.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            topPresentedController().present(alert, animated: true)
            return
        }
        tracks.forEach(rememberQobuz)
        activateQobuzPlaybackBackend(credentials: credentials)
        guard let playback = playback else { return }
        playback.setQueue(trackIDs: tracks.map(\.id), startingAt: index)
        playback.play()
        openPlayer()
    }

    private func ensureQobuzPlaybackBackend() -> Bool {
        if playbackBackendOverride is QobuzPlaybackController { return true }
        guard let credentials = QobuzCredentialStore.shared.load() else {
            showCatalogError(QobuzStreamingError.notAuthenticated)
            return false
        }
        activateQobuzPlaybackBackend(credentials: credentials)
        return true
    }

    private func activateQobuzPlaybackBackend(credentials: QobuzCredentials) {
        let provider: (String) -> ScreenTrack? = { [weak self] id in self?.qobuzPresentationTracks[id] }
        let backend = QobuzPlaybackController(
            client: QobuzStreamingClient(credentials: credentials),
            quality: { QobuzPreferences.quality },
            trackProvider: provider
        )
        activatePlaybackBackend(backend, presentationTrackProvider: provider)
    }

    private func registerQobuzTrack(_ track: ScreenTrack) {
        qobuzPresentationTracks[track.id] = track
        if let albumID = track.catalogAlbumID { qobuzCatalogAlbumIDByTrackID[track.id] = albumID }
        if let artistID = track.catalogArtistID { qobuzCatalogArtistIDByName[track.artist.lowercased()] = artistID }
        guard let url = track.artworkURL else { return }
        ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: 320) { [weak self] image in
            guard let self = self, let image = image,
                  let current = self.qobuzPresentationTracks[track.id] else { return }
            self.qobuzPresentationTracks[track.id] = ScreenTrack(
                id: current.id, title: current.title, artist: current.artist, album: current.album,
                quality: current.quality, artwork: image, artworkURL: current.artworkURL,
                catalogAlbumID: current.catalogAlbumID, catalogArtistID: current.catalogArtistID, duration: current.duration
            )
            self.updatePlaybackViews(queue: self.queueState)
        }
    }

    private func rememberQobuz(_ track: ScreenTrack) {
        registerQobuzTrack(track)
        if let albumID = track.catalogAlbumID {
            qobuzCatalogAlbumIDByTrackID[track.id] = albumID
            qobuzCatalogAlbumIDs.insert(albumID)
        }
        if let artistID = track.catalogArtistID {
            qobuzCatalogArtistIDByName[track.artist.lowercased()] = artistID
        }
    }

    private func rememberQobuz(profile: ScreenProfile) {
        qobuzCatalogArtistIDByName[profile.name.lowercased()] = profile.id
        profile.tracks.forEach(rememberQobuz)
        profile.albums.forEach { album in
            qobuzCatalogAlbumIDs.insert(album.id)
            album.tracks.forEach(rememberQobuz)
        }
    }

    private func showQobuzAlbum(_ album: ScreenAlbum, credentials: QobuzCredentials, from presentingController: UIViewController? = nil) {
        if qobuzPrimaryArtistByAlbumID[album.id] != nil,
           !album.tracks.isEmpty,
           album.tracks.allSatisfy({ $0.catalogAlbumID == album.id || qobuzPresentationTracks[$0.id] != nil }) {
            presentQobuzAlbum(album, from: presentingController)
            return
        }
        let client = QobuzStreamingClient(credentials: credentials)
        client.album(id: album.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure(let error):
                    self.showCatalogError(error)
                case .success(let detail):
                    // This association exists even when the album has no tracks.
                    // Never infer the album artist from the first track performer.
                    if let primaryArtist = detail.artist, !primaryArtist.id.isEmpty {
                        self.qobuzPrimaryArtistByAlbumID[detail.id] = (primaryArtist.id, primaryArtist.name)
                    } else {
                        self.qobuzPrimaryArtistByAlbumID.removeValue(forKey: detail.id)
                    }
                    let mapped = QobuzCatalogMapper.album(detail)
                    let artwork = detail.artworkURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: $0.absoluteString) }
                    let tracks = mapped.tracks.map { track in
                        ScreenTrack(
                            id: track.id,
                            title: track.title,
                            artist: track.artist,
                            album: track.album,
                            quality: track.quality,
                            artwork: artwork,
                            artworkURL: track.artworkURL,
                            catalogAlbumID: track.catalogAlbumID,
                            catalogArtistID: track.catalogArtistID,
                            duration: track.duration
                        )
                    }
                    let screenAlbum = ScreenAlbum(
                        id: mapped.id,
                        title: mapped.title,
                        artist: mapped.artist,
                        year: mapped.year,
                        genre: mapped.genre,
                        quality: mapped.quality,
                        artwork: artwork,
                        artworkURL: mapped.artworkURL,
                        tracks: tracks
                    )
                    self.qobuzCatalogAlbumIDs.insert(screenAlbum.id)
                    screenAlbum.tracks.forEach(self.rememberQobuz)
                    self.presentQobuzAlbum(screenAlbum, from: presentingController)
                }
            }
        }
    }

    private func presentQobuzAlbum(_ album: ScreenAlbum, from presentingController: UIViewController? = nil) {
        qobuzCatalogAlbumIDs.insert(album.id)
        qobuzAlbumTracksByID[album.id] = album.tracks
        album.tracks.forEach(rememberQobuz)
        let controller = AlbumDetailViewController(album: album)
        controller.modalPresentationStyle = .fullScreen
        controller.onDismissSwipe = { [weak controller] in
            guard let controller = controller else { return }
            InteractionMotion.dismiss(controller)
        }
        controller.onTrackSelected = { [weak self] track in self?.start(track: track) }
        controller.onTrackNavigationRequested = { [weak self] track in self?.showTrackNavigationMenu(for: track) }
        controller.onSongSwipeAction = { [weak self] track, action in self?.handleSongSwipe(action, track: track) }
        controller.onAlbumQueueRequested = { [weak self] selectedAlbum in self?.showAlbumQueueMenu(for: selectedAlbum) }
        controller.onArtistSelected = { [weak self, weak controller] _ in
            guard let self = self,
                  let primaryArtist = self.qobuzPrimaryArtistByAlbumID[album.id],
                  let credentials = QobuzCredentialStore.shared.load() else { return }
            self.showQobuzArtist(ScreenProfile(id: primaryArtist.id, name: primaryArtist.name, subtitle: "Qobuz artist", information: "", albums: []), credentials: credentials, from: controller)
        }
        controller.onPlayAlbum = { [weak self] tracks, shuffle in
            guard let self = self else { return }
            let ordered = shuffle ? tracks.shuffled() : tracks
            guard !ordered.isEmpty else { return }
            ordered.forEach(self.rememberQobuz)
            self.playQobuz(tracks: ordered, startingAt: 0, quality: QobuzPreferences.quality)
        }
        InteractionMotion.present(controller, from: presentingController ?? self)
    }

    private func showQobuzPlaylist(_ playlist: QobuzCatalogPlaylist, from presentingController: UIViewController? = nil) {
        let controller = QobuzPlaylistDetailViewController(playlist: playlist)
        controller.modalPresentationStyle = .fullScreen
        controller.onTrackSelected = { [weak self] track in
            guard let self = self else { return }
            self.rememberQobuz(track)
            self.playQobuz(track: track, quality: QobuzPreferences.quality)
        }
        controller.onPlayRequested = { [weak self] tracks, shuffle in
            guard let self = self else { return }
            let orderedTracks = shuffle ? tracks.shuffled() : tracks
            guard !orderedTracks.isEmpty else { return }
            orderedTracks.forEach(self.rememberQobuz)
            self.playQobuz(tracks: orderedTracks, startingAt: 0, quality: QobuzPreferences.quality)
        }
        InteractionMotion.present(controller, from: presentingController ?? self)
    }

    private func showQobuzArtist(_ artist: ScreenProfile, credentials: QobuzCredentials, from presentingController: UIViewController? = nil) {
        guard !artist.id.isEmpty else {
            showCatalogError(QobuzStreamingError.invalidResponse)
            return
        }
        let client = QobuzStreamingClient(credentials: credentials)
        client.artist(id: artist.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure(let error): self.showCatalogError(error)
                case .success(let detail):
                    let profile = QobuzCatalogMapper.profile(detail)
                    self.qobuzCatalogArtistIDByName[profile.name.lowercased()] = profile.id
                    self.rememberQobuz(profile: profile)
                    self.showProfile(profile, from: presentingController)
                }
            }
        }
    }

    private func showCatalogError(_ error: Error) {
        let alert = UIAlertController(title: "Qobuz Catalog Error", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        topPresentedController().present(alert, animated: true)
    }

    private func handleQobuzAccountAction() {
        guard QobuzCredentialStore.shared.load() != nil else {
            showQobuzStreamTest(autoStartSignIn: true)
            return
        }
        let alert = UIAlertController(title: "Qobuz Account", message: "Sign out of Qobuz on this device?", preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Sign Out", style: .destructive) { [weak self] _ in
            QobuzCredentialStore.shared.delete()
            self?.tabControllers.removeAll()
            self?.open(tab: .discover, direction: nil)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        let presenter = topPresentedController()
        if let popover = alert.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1)
        }
        presenter.present(alert, animated: true)
    }

    private func showQobuzStreamTest(autoStartSignIn: Bool = false) {
        let controller = QobuzAccountViewController()
        controller.startsSignInAutomatically = autoStartSignIn
        controller.onAccountChanged = { [weak self] in
            guard let self = self else { return }
            let returnTab = self.appState.currentTab
            self.tabControllers.removeAll()
            self.open(tab: returnTab, direction: nil)
        }
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }

    private func showLegacyQobuzStreamTest() {
        let controller = QobuzStreamTestViewController()
        controller.onPlayInApp = { [weak self, weak controller] searchTrack, selectedQuality in
            guard let self = self, let controller = controller,
                  let credentials = QobuzCredentialStore.shared.load() else { return }
            let artworkURL = searchTrack.album?.imageURL
            let screenTrack = ScreenTrack(
                id: String(searchTrack.id),
                title: searchTrack.title,
                artist: searchTrack.performer?.name ?? "Unknown Artist",
                album: searchTrack.album?.title ?? "Unknown Album",
                quality: selectedQuality.title,
                artworkURL: artworkURL,
                catalogAlbumID: searchTrack.album?.id,
                catalogArtistID: searchTrack.performer?.id,
                duration: TimeInterval(searchTrack.duration ?? 0)
            )
            self.rememberQobuz(screenTrack)
            if let artworkURL = artworkURL {
                ArtworkImagePipeline.shared.image(forRemoteURL: artworkURL, maximumPixelSize: 320) { [weak self] artwork in
                    guard let self = self, let artwork = artwork else { return }
                    guard let current = self.qobuzPresentationTracks[screenTrack.id] else { return }
                    self.qobuzPresentationTracks[screenTrack.id] = ScreenTrack(
                        id: current.id,
                        title: current.title,
                        artist: current.artist,
                        album: current.album,
                        quality: current.quality,
                        artwork: artwork,
                        artworkURL: current.artworkURL,
                        catalogAlbumID: current.catalogAlbumID,
                        catalogArtistID: current.catalogArtistID,
                        duration: current.duration
                    )
                    self.updatePlaybackViews(queue: self.queueState)
                }
            }
            let provider: (String) -> ScreenTrack? = { [weak self] id in self?.qobuzPresentationTracks[id] }
            let backend = QobuzPlaybackController(
                client: QobuzStreamingClient(credentials: credentials),
                quality: { selectedQuality },
                trackProvider: provider
            )
            self.activatePlaybackBackend(backend, presentationTrackProvider: provider)
            InteractionMotion.dismiss(controller) {
                self.play(tracks: [screenTrack], startingAt: 0, preserveBackend: true)
            }
        }
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }


}
