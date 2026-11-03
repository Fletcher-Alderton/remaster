import UIKit

/// Album page (requirements ALB-01…ALB-04): compact header modelled on the reference,
/// one quality summary, a single download status control, an overflow menu for library,
/// queue and share actions, and per-track saved/download indicators.
final class AlbumDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    var album: ScreenAlbum {
        didSet {
            if album.id != oldValue.id {
                libraryGeneration = UUID()
                librarySaved = nil
                libraryBusy = false
                libraryError = nil
                savedTrackIDs = []
                configureDownloads(manager: nil, tracks: [], quality: downloadQuality)
            }
            reload()
        }
    }

    // MARK: Downloads

    private var downloadManager: QobuzDownloadManager?
    private var downloadTracks: [QobuzSearchTrack] = []
    private var downloadQuality: QobuzStreamQuality = .cd
    private var downloadError: String?
    private var downloadObservation: NSObjectProtocol?

    func configureDownloads(manager: QobuzDownloadManager?, tracks: [QobuzSearchTrack], quality: QobuzStreamQuality, error: String? = nil) {
        if let observation = downloadObservation { NotificationCenter.default.removeObserver(observation) }
        downloadManager = manager
        downloadTracks = tracks
        downloadQuality = quality
        downloadError = error
        if let manager = manager {
            downloadObservation = NotificationCenter.default.addObserver(forName: QobuzDownloadManager.didChange, object: manager, queue: .main) { [weak self] _ in self?.reload() }
        }
        reload()
    }

    deinit { if let observation = downloadObservation { NotificationCenter.default.removeObserver(observation) } }

    private var downloadStates: [QobuzDownloadState] {
        downloadTracks.map { downloadManager?.state(trackID: $0.id, quality: downloadQuality) ?? .notDownloaded }
    }

    /// One compact status control replaces the old buttons and "n/n downloaded" counter.
    enum DownloadPill: Equatable {
        case unavailable, idle, active(percent: Int), failed(count: Int), cancelled, done

        var title: String {
            switch self {
            case .unavailable, .idle: return "DOWNLOAD"
            case .active(let percent): return "DOWNLOADING \(percent)%"
            case .failed(let count): return "RETRY · \(count) FAILED"
            case .cancelled: return "RETRY DOWNLOAD"
            case .done: return "DOWNLOADED"
            }
        }

        var glyph: AlbumGlyph {
            switch self {
            case .done: return .check
            case .active: return .cross
            case .failed: return .warning
            case .unavailable, .idle, .cancelled: return .download
            }
        }

        var hint: String? {
            switch self {
            case .active: return "Cancels the download"
            case .failed, .cancelled: return "Retries the remaining tracks"
            case .idle: return "Downloads the album for offline playback"
            case .unavailable: return "Available once the full album has loaded"
            case .done: return nil
            }
        }
    }

    private var downloadPill: DownloadPill {
        guard downloadManager != nil, !downloadTracks.isEmpty else { return .unavailable }
        let states = downloadStates
        if states.contains(where: { switch $0 { case .queued, .resolving, .downloading: return true; default: return false } }) {
            let progress = states.reduce(0.0) { total, state in
                switch state { case .downloaded: return total + 1; case .downloading(let value): return total + value; default: return total }
            }
            return .active(percent: Int(progress / Double(states.count) * 100))
        }
        if states.allSatisfy({ $0 == .downloaded }) { return .done }
        let failed = states.filter { if case .failed = $0 { return true }; return false }.count
        if failed > 0 { return .failed(count: failed) }
        if states.contains(.cancelled) { return .cancelled }
        return .idle
    }

    private func downloadTapped() {
        guard let manager = downloadManager, !downloadTracks.isEmpty else { return }
        downloadError = nil
        switch downloadPill {
        case .unavailable, .done:
            return
        case .active:
            for track in downloadTracks { manager.cancel(trackID: track.id, quality: downloadQuality) }
        case .idle, .failed, .cancelled:
            do { try manager.downloadAlbum(tracks: downloadTracks, quality: downloadQuality) }
            catch { downloadError = error.localizedDescription }
        }
        reload()
    }

    private func removeDownloads() {
        guard let manager = downloadManager else { return }
        downloadError = nil
        do { for track in downloadTracks { try manager.delete(trackID: track.id, quality: downloadQuality) } }
        catch { downloadError = error.localizedDescription }
        reload()
    }

    private func downloadState(for track: ScreenTrack) -> QobuzDownloadState? {
        guard let manager = downloadManager, let id = Int64(track.id),
              downloadTracks.contains(where: { $0.id == id }) else { return nil }
        return manager.state(trackID: id, quality: downloadQuality)
    }

    // MARK: Library

    // The owner supplies authenticated favorites reads/mutations. Unknown state
    // must never be guessed to mean an unsaved album.
    var onLibraryChangeRequested: ((String, Bool, @escaping (Result<Void, Error>) -> Void) -> Void)? { didSet { reload() } }
    private var librarySaved: Bool?
    private var libraryBusy = false
    private var libraryError: String?
    private var libraryGeneration = UUID()
    private var savedTrackIDs: Set<String> = []

    func configureLibrary(isSaved: Bool?, error: String? = nil) {
        libraryGeneration = UUID()
        librarySaved = isSaved
        libraryBusy = false
        libraryError = error
        reload()
    }

    /// Individually saved tracks get a star (separate from the download icon).
    func configureSavedTracks(_ ids: Set<String>) {
        savedTrackIDs = ids
        reload()
    }

    private func changeLibrary(to target: Bool) {
        guard !libraryBusy, librarySaved != nil, let request = onLibraryChangeRequested else { return }
        let generation = UUID()
        libraryGeneration = generation
        libraryBusy = true
        libraryError = nil
        reload()
        request(album.id, target) { [weak self] result in
            let update = { [weak self] in
                guard let self = self, self.libraryGeneration == generation else { return }
                // Ignore duplicate completions as well as responses for replaced albums.
                self.libraryGeneration = UUID()
                self.libraryBusy = false
                switch result {
                case .success: self.librarySaved = target
                case .failure: self.libraryError = "Could not update library. Try again."
                }
                self.reload()
            }
            if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
        }
    }

    // MARK: Menu

    var onQueueAction: ((ScreenAlbum, AlbumQueueAction) -> Void)?
    /// Presents a destructive confirmation; replaced in tests.
    lazy var confirm: (String, String, @escaping () -> Void) -> Void = { [weak self] title, message, confirmed in
        guard let self = self else { return }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { _ in confirmed() })
        self.present(alert, animated: true)
    }

    static func shareURL(for album: ScreenAlbum) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !album.id.isEmpty, let id = album.id.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://open.qobuz.com/album/\(id)")
    }

    /// Reference B order. Only "Add to a Playlist…" is an intentional placeholder; Love and
    /// Dislike stay visibly unavailable until a Qobuz preference API is verified.
    func albumActions() -> [AlbumAction] {
        let library: AlbumAction
        switch (librarySaved, libraryBusy) {
        case (nil, _):
            library = AlbumAction(id: .library, title: "Add to Library", detail: libraryError == nil ? "Checking library…" : "Unavailable",
                                  glyph: .plus, isEnabled: false)
        case (let saved?, true):
            library = AlbumAction(id: .library, title: saved ? "Removing…" : "Adding…", glyph: saved ? .trash : .plus,
                                  isEnabled: false, isDestructive: saved)
        case (true, false):
            library = AlbumAction(id: .library, title: "Remove…", glyph: .trash, isEnabled: onLibraryChangeRequested != nil,
                                  isDestructive: true) { [weak self] in
                self?.confirm("Remove from Library?", "Downloaded files stay on this iPod.") { self?.changeLibrary(to: false) }
            }
        case (false, false):
            library = AlbumAction(id: .library, title: "Add to Library", glyph: .plus,
                                  isEnabled: onLibraryChangeRequested != nil) { [weak self] in self?.changeLibrary(to: true) }
        }
        let album = self.album
        var actions = [
            library,
            AlbumAction(id: .playlist, title: "Add to a Playlist…", detail: "Coming soon", glyph: .playlistAdd, isEnabled: false),
            AlbumAction(id: .playNext, title: "Play Next", glyph: .playNext, isEnabled: !album.tracks.isEmpty || onQueueAction != nil) { [weak self] in
                self?.onQueueAction?(album, .playNext)
            },
            AlbumAction(id: .playLater, title: "Play Later", glyph: .playLater, isEnabled: !album.tracks.isEmpty || onQueueAction != nil) { [weak self] in
                self?.onQueueAction?(album, .enqueue)
            },
            AlbumAction(id: .share, title: "Share Album…", glyph: .share, isEnabled: Self.shareURL(for: album) != nil) { [weak self] in
                self?.share()
            },
            AlbumAction(id: .love, title: "Love", detail: "Unavailable", glyph: .heart, isEnabled: false),
            AlbumAction(id: .dislike, title: "Dislike", detail: "Unavailable", glyph: .heartSlash, isEnabled: false)
        ]
        if downloadStates.contains(.downloaded) {
            actions.append(AlbumAction(id: .removeDownload, title: "Remove Download…", glyph: .trash, isDestructive: true) { [weak self] in
                self?.confirm("Remove Download?", "The album stays in your library.") { self?.removeDownloads() }
            })
        }
        return actions
    }

    private func share() {
        guard let url = Self.shareURL(for: album) else { return }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func showMenu() {
        let sheet = AlbumActionSheetController(album: album, actions: albumActions()) { [weak self] in
            guard let self = self else { return }
            self.onPlayAlbum?(self.album.tracks, false)
        }
        present(sheet, animated: true)
    }

    // MARK: Lifecycle

    var onTrackSelected: ((ScreenTrack) -> Void)?
    var onTrackNavigationRequested: ((ScreenTrack) -> Void)?
    var onSongSwipeAction: ((ScreenTrack, SongSwipeAction) -> Void)?
    var onArtistSelected: ((String) -> Void)?
    var onDismissSwipe: (() -> Void)?
    var onPlayAlbum: (([ScreenTrack], Bool) -> Void)?
    private let table = UITableView(frame: .zero, style: .plain)
    private var songSwipeCoordinator: SongListSwipeCoordinator?

    init(album: ScreenAlbum) {
        self.album = album
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "albumDetail"
        view.backgroundColor = DesignSystem.pageBackground
        table.backgroundColor = DesignSystem.pageBackground
        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.delegate = self
        table.estimatedRowHeight = 0
        table.separatorColor = ScreenPalette.separator
        table.showsVerticalScrollIndicator = false
        table.register(AlbumTrackCell.self, forCellReuseIdentifier: AlbumTrackCell.reuseID)
        view.addSubview(table)
        installHeader()
        songSwipeCoordinator = SongListSwipeCoordinator(tableView: table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let dismissGesture = UISwipeGestureRecognizer(target: self, action: #selector(dismissSwipe(_:)))
        dismissGesture.direction = .down
        dismissGesture.delegate = self
        view.addGestureRecognizer(dismissGesture)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = table.tableHeaderView, header.frame.width != table.bounds.width else { return }
        installHeader()
    }

    private func installHeader() {
        let header = AlbumHeader(model: AlbumHeader.Model(
            album: album,
            quality: Self.qualitySummary(album.quality),
            download: downloadPill,
            status: libraryError ?? downloadError
        ))
        header.onArtist = { [weak self] in self?.onArtistSelected?(self?.album.artist ?? "") }
        header.onMore = { [weak self] in self?.showMenu() }
        header.onDownload = { [weak self] in self?.downloadTapped() }
        header.onPlay = { [weak self] shuffle in
            guard let self = self else { return }
            self.onPlayAlbum?(self.album.tracks, shuffle)
        }
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(albumHeaderLongPressed(_:)))
        longPress.minimumPressDuration = 0.45
        header.addGestureRecognizer(longPress)
        let width = max(table.bounds.width, 296)
        let height = header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        header.frame = CGRect(x: 0, y: 0, width: width, height: ceil(height))
        table.tableHeaderView = header
    }

    private func reload() {
        guard isViewLoaded else { return }
        installHeader()
        table.reloadData()
    }

    @objc private func dismissSwipe(_ recognizer: UISwipeGestureRecognizer) {
        let topOffset = -table.adjustedContentInset.top
        guard table.contentOffset.y <= topOffset + 1 else { return }
        onDismissSwipe?()
    }

    @objc private func albumHeaderLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        showMenu()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { return true }

    // MARK: Table

    private func showsSubtitle(_ track: ScreenTrack) -> Bool {
        !track.artist.isEmpty && track.artist.caseInsensitiveCompare(album.artist) != .orderedSame
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { album.tracks.count }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        showsSubtitle(album.tracks[indexPath.row]) ? 56 : 48
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let track = album.tracks[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: AlbumTrackCell.reuseID, for: indexPath) as! AlbumTrackCell
        cell.configure(track: track, number: indexPath.row + 1, subtitle: showsSubtitle(track) ? track.artist : nil,
                       isSaved: savedTrackIDs.contains(track.id), download: downloadState(for: track))
        cell.onSwipeAction = { [weak self] action in self?.onSongSwipeAction?(track, action) }
        cell.onLongPress = { [weak self] in self?.onTrackNavigationRequested?(track) }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onTrackSelected?(album.tracks[indexPath.row])
    }
    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) { if let cell = tableView.cellForRow(at: indexPath) { InteractionMotion.setRow(cell, highlighted: true) } }
    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) { if let cell = tableView.cellForRow(at: indexPath) { InteractionMotion.setRow(cell, highlighted: false) } }

    // MARK: Quality

    /// One concise availability line ("Hi-Res · 24-bit / 96 kHz") from Qobuz's
    /// "24-bit / 96000 Hz" album maximum. Never phrased as requested or measured output.
    static func qualitySummary(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let parts = text.components(separatedBy: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let depth = Int(parts[0].replacingOccurrences(of: "-bit", with: "")) else { return text }
        var detail = "\(depth)-bit"
        var rate: Double?
        if parts.count > 1, let hertz = Double(parts[1].replacingOccurrences(of: "Hz", with: "").trimmingCharacters(in: .whitespaces)) {
            rate = hertz
            let kilohertz = hertz / 1000
            let formatted = kilohertz.rounded() == kilohertz ? String(Int(kilohertz)) : String(format: "%.1f", kilohertz)
            detail += " / \(formatted) kHz"
        }
        let hiRes = depth > 16 || (rate ?? 0) > 48_000
        return "\(hiRes ? "Hi-Res" : "CD") · \(detail)"
    }
}

/// Reference A header: 102 pt cover at the left; title, artist, genre • year and the
/// quality line to its right; download status and the round "more" button under the text;
/// then equal Play/Shuffle buttons between hairline dividers.
private final class AlbumHeader: UIView {
    struct Model {
        let album: ScreenAlbum
        let quality: String
        let download: AlbumDetailViewController.DownloadPill
        let status: String?
    }

    var onArtist: (() -> Void)?
    var onMore: (() -> Void)?
    var onDownload: (() -> Void)?
    var onPlay: ((Bool) -> Void)?

    private let art = ArtworkView(image: nil, cornerRadius: DesignSystem.albumArtworkCornerRadius)
    private lazy var artworkLoader = DetailArtworkLoader(artworkView: art)

    init(model: Model) {
        super.init(frame: .zero)
        accessibilityIdentifier = "albumDetail.header"
        backgroundColor = DesignSystem.pageBackground
        let album = model.album

        artworkLoader.configure(image: album.artwork, url: album.artworkURL)
        artworkLoader.load(pointSize: 102)

        let title = ScreenPalette.label(album.title, font: .systemFont(ofSize: 17, weight: .bold), lines: 3)
        title.accessibilityIdentifier = "albumDetail.title"
        title.lineBreakMode = .byTruncatingTail
        let artist = UIButton(type: .system)
        artist.accessibilityIdentifier = "albumDetail.artist"
        artist.setTitle(album.artist, for: .normal)
        artist.setTitleColor(ScreenPalette.accent, for: .normal)
        artist.contentHorizontalAlignment = .left
        artist.titleLabel?.font = .systemFont(ofSize: 16)
        artist.titleLabel?.numberOfLines = 2
        artist.titleLabel?.lineBreakMode = .byTruncatingTail
        artist.contentEdgeInsets = .zero
        artist.addActionCompat { [weak self] in self?.onArtist?() }
        let metadata = [album.genre, album.year].filter { !$0.isEmpty }.joined(separator: " • ")
        let info = ScreenPalette.label(metadata, font: .systemFont(ofSize: 15), color: ScreenPalette.secondary)
        info.isHidden = metadata.isEmpty
        let quality = ScreenPalette.label(model.quality, font: .systemFont(ofSize: 12, weight: .medium), color: ScreenPalette.secondary)
        quality.accessibilityIdentifier = "albumDetail.quality"
        quality.isHidden = model.quality.isEmpty
        let text = UIStackView(arrangedSubviews: [title, artist, info, quality])
        text.axis = .vertical
        text.spacing = 1
        text.setCustomSpacing(3, after: info)
        text.translatesAutoresizingMaskIntoConstraints = false
        // Text is never squeezed to keep the ⋯ button level with the cover; the row moves down instead.
        for view in [title, artist, info, quality] { view.setContentCompressionResistancePriority(.required, for: .vertical) }

        let download = UIButton(type: .custom)
        download.translatesAutoresizingMaskIntoConstraints = false
        download.accessibilityIdentifier = "albumDetail.download"
        download.setTitle(model.download.title, for: .normal)
        download.setImage(model.download.glyph.image(size: 12), for: .normal)
        let downloadTint = model.download == .done || model.download == .unavailable ? ScreenPalette.secondary : ScreenPalette.accent
        download.tintColor = downloadTint
        download.setTitleColor(downloadTint, for: .normal)
        download.titleLabel?.font = .systemFont(ofSize: 12, weight: .semibold)
        download.titleLabel?.adjustsFontSizeToFitWidth = true
        download.titleLabel?.minimumScaleFactor = 0.8
        download.contentHorizontalAlignment = .left
        download.titleEdgeInsets = UIEdgeInsets(top: 0, left: 5, bottom: 0, right: -5)
        download.accessibilityHint = model.download.hint
        download.addActionCompat { [weak self] in self?.onDownload?() }

        let more = UIButton(type: .custom)
        more.translatesAutoresizingMaskIntoConstraints = false
        more.accessibilityIdentifier = "albumDetail.more"
        more.accessibilityLabel = "More"
        more.backgroundColor = ScreenPalette.accent
        more.layer.cornerRadius = 14
        more.setImage(AlbumGlyph.more.image(size: 16), for: .normal)
        more.tintColor = .white
        more.addActionCompat { [weak self] in self?.onMore?() }

        let topDivider = Self.divider()
        let play = Self.actionButton(title: "Play", glyph: AlbumGlyph.play.image(size: 14))
        play.accessibilityIdentifier = "albumDetail.play"
        play.addActionCompat { [weak self] in self?.onPlay?(false) }
        let shuffle = Self.actionButton(title: "Shuffle", glyph: MusicSymbol.shuffle(size: CGSize(width: 18, height: 18)).withRenderingMode(.alwaysTemplate))
        shuffle.accessibilityIdentifier = "albumDetail.shuffle"
        shuffle.addActionCompat { [weak self] in self?.onPlay?(true) }
        let bottomDivider = Self.divider()

        let status = ScreenPalette.label(model.status ?? "", font: .systemFont(ofSize: 13), color: ScreenPalette.secondary, lines: 2)
        status.accessibilityIdentifier = "albumDetail.status"
        status.isHidden = (model.status ?? "").isEmpty

        [art, text, download, more, topDivider, play, shuffle, bottomDivider, status].forEach(addSubview)
        let moreBelowArt = more.bottomAnchor.constraint(equalTo: art.bottomAnchor)
        moreBelowArt.priority = .defaultLow
        let dividerBelowArt = topDivider.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 14)
        dividerBelowArt.priority = .defaultLow
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            art.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            art.widthAnchor.constraint(equalToConstant: 102),
            art.heightAnchor.constraint(equalToConstant: 102),

            text.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: art.topAnchor, constant: 2),

            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            more.widthAnchor.constraint(equalToConstant: 28),
            more.heightAnchor.constraint(equalToConstant: 28),
            moreBelowArt,
            more.topAnchor.constraint(greaterThanOrEqualTo: text.bottomAnchor, constant: 6),
            download.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            download.trailingAnchor.constraint(lessThanOrEqualTo: more.leadingAnchor, constant: -8),
            download.centerYAnchor.constraint(equalTo: more.centerYAnchor),
            download.heightAnchor.constraint(equalToConstant: 28),

            topDivider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            topDivider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            dividerBelowArt,
            topDivider.topAnchor.constraint(greaterThanOrEqualTo: art.bottomAnchor, constant: 14),
            topDivider.topAnchor.constraint(greaterThanOrEqualTo: more.bottomAnchor, constant: 12),
            topDivider.heightAnchor.constraint(equalToConstant: 0.5),

            play.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            play.topAnchor.constraint(equalTo: topDivider.bottomAnchor, constant: 12),
            play.heightAnchor.constraint(equalToConstant: 48),
            shuffle.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 20),
            shuffle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            shuffle.topAnchor.constraint(equalTo: play.topAnchor),
            shuffle.heightAnchor.constraint(equalTo: play.heightAnchor),
            shuffle.widthAnchor.constraint(equalTo: play.widthAnchor),

            bottomDivider.leadingAnchor.constraint(equalTo: topDivider.leadingAnchor),
            bottomDivider.trailingAnchor.constraint(equalTo: topDivider.trailingAnchor),
            bottomDivider.topAnchor.constraint(equalTo: play.bottomAnchor, constant: 12),
            bottomDivider.heightAnchor.constraint(equalToConstant: 0.5),

            status.leadingAnchor.constraint(equalTo: topDivider.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: topDivider.trailingAnchor),
            status.topAnchor.constraint(equalTo: bottomDivider.bottomAnchor, constant: status.isHidden ? 0 : 8),
            status.bottomAnchor.constraint(equalTo: bottomAnchor, constant: status.isHidden ? 0 : -8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func divider() -> UIView {
        let line = UIView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.backgroundColor = ScreenPalette.separator
        return line
    }

    private static func actionButton(title: String, glyph: UIImage) -> UIButton {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setImage(glyph, for: .normal)
        button.tintColor = ScreenPalette.accent
        button.setTitleColor(ScreenPalette.accent, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        button.titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
        button.backgroundColor = ScreenPalette.softFill
        button.layer.cornerRadius = 8
        return button
    }
}

// A table keeps top tracks on the same swipe/long-press path as album tracks.
// Release rows retain the two-column grid without nesting scroll views.
final class ProfileDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    var profile: ScreenProfile { didSet { reload() } }
    var onAlbumSelected: ((ScreenAlbum) -> Void)?
    var onAlbumQueueRequested: ((ScreenAlbum) -> Void)?
    var onTrackSelected: ((ScreenTrack) -> Void)?
    /// The tapped top track followed by every track below it, in displayed order.
    var onPlayTracks: (([ScreenTrack]) -> Void)?
    var onTrackNavigationRequested: ((ScreenTrack) -> Void)?
    var onSongSwipeAction: ((ScreenTrack, SongSwipeAction) -> Void)?
    var onDismissSwipe: (() -> Void)?

    private enum Section: Equatable { case tracks, releases(Int) }
    private var sections: [Section] {
        var result: [Section] = []
        if !profile.tracks.isEmpty { result.append(.tracks) }
        result += profile.releaseSections.indices.map { .releases($0) }
        return result
    }
    private let table = UITableView(frame: .zero, style: .plain)
    private var songSwipeCoordinator: SongListSwipeCoordinator?

    init(profile: ScreenProfile) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "profileDetail"
        view.backgroundColor = DesignSystem.pageBackground
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = DesignSystem.pageBackground
        table.alwaysBounceVertical = true
        table.showsVerticalScrollIndicator = false
        table.separatorStyle = .none
        table.contentInset.bottom = 90
        table.dataSource = self
        table.delegate = self
        table.register(ProfileTrackCell.self, forCellReuseIdentifier: ProfileTrackCell.reuseID)
        table.register(ProfileAlbumRowCell.self, forCellReuseIdentifier: ProfileAlbumRowCell.reuseID)
        table.tableHeaderView = ProfileHeader(profile: profile)
        view.addSubview(table)
        songSwipeCoordinator = SongListSwipeCoordinator(tableView: table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: view.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let dismissGesture = UISwipeGestureRecognizer(target: self, action: #selector(dismissSwipe(_:)))
        dismissGesture.direction = .down
        dismissGesture.delegate = self
        view.addGestureRecognizer(dismissGesture)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        sizeHeaderToFit()
    }

    private func reload() {
        guard isViewLoaded else { return }
        table.tableHeaderView = ProfileHeader(profile: profile)
        table.reloadData()
        sizeHeaderToFit()
    }

    private func sizeHeaderToFit() {
        guard let header = table.tableHeaderView, table.bounds.width > 0 else { return }
        let width = table.bounds.width
        let height = ceil(header.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height)
        let size = CGSize(width: width, height: height)
        guard header.frame.size != size else { return }
        header.frame = CGRect(origin: .zero, size: size)
        table.tableHeaderView = header
    }

    @objc private func dismissSwipe(_ recognizer: UISwipeGestureRecognizer) {
        let topOffset = -table.adjustedContentInset.top
        guard table.contentOffset.y <= topOffset + 1 else { return }
        onDismissSwipe?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { return true }

    func numberOfSections(in tableView: UITableView) -> Int { return sections.count }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .tracks: return profile.tracks.count
        case .releases(let index): return (profile.releaseSections[index].albums.count + 1) / 2
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView()
        header.backgroundColor = DesignSystem.pageBackground
        let title: String
        switch sections[section] {
        case .tracks: title = "Top Tracks"
        case .releases(let index):
            let release = profile.releaseSections[index]
            title = release.title + (release.failed ? " — Loading failed" : "")
        }
        let label = ScreenPalette.label(title, font: .systemFont(ofSize: 20, weight: .bold), lines: 2)
        header.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: header.centerYAnchor)
        ])
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat { return 40 }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return sections[indexPath.section] == .tracks ? 62 : floor((tableView.bounds.width - 44) / 2) + 70
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .tracks:
            let track = profile.tracks[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: ProfileTrackCell.reuseID, for: indexPath) as! ProfileTrackCell
            cell.configure(track: track, number: indexPath.row + 1)
            cell.onSwipeAction = { [weak self] action in self?.onSongSwipeAction?(track, action) }
            cell.onLongPress = { [weak self] in self?.onTrackNavigationRequested?(track) }
            return cell
        case .releases(let index):
            let albums = profile.releaseSections[index].albums
            let cell = tableView.dequeueReusableCell(withIdentifier: ProfileAlbumRowCell.reuseID, for: indexPath) as! ProfileAlbumRowCell
            let firstIndex = indexPath.row * 2
            let secondIndex = firstIndex + 1
            cell.configure(
                first: albums[firstIndex],
                second: albums.indices.contains(secondIndex) ? albums[secondIndex] : nil,
                onSelected: { [weak self] in self?.onAlbumSelected?($0) },
                onQueueRequested: { [weak self] in self?.onAlbumQueueRequested?($0) }
            )
            return cell
        }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? ProfileTrackCell)?.loadArtwork()
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? ProfileTrackCell)?.stopArtwork()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections[indexPath.section] == .tracks else { return }
        if let onPlayTracks = onPlayTracks {
            onPlayTracks(Array(profile.tracks[indexPath.row...]))
        } else {
            onTrackSelected?(profile.tracks[indexPath.row])
        }
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        guard sections[indexPath.section] == .tracks, let cell = tableView.cellForRow(at: indexPath) else { return }
        InteractionMotion.setRow(cell, highlighted: true)
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        guard let cell = tableView.cellForRow(at: indexPath) else { return }
        InteractionMotion.setRow(cell, highlighted: false)
    }
}

private final class ProfileTrackCell: SongSwipeActionCell {
    static let reuseID = "ProfileTrackCell"
    private let art = ArtworkView(image: nil)
    private lazy var artworkLoader = DetailArtworkLoader(artworkView: art)
    private let title = ScreenPalette.label(font: .systemFont(ofSize: 17))
    private let meta = ScreenPalette.label(font: .systemFont(ofSize: 13), color: ScreenPalette.secondary)

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        art.translatesAutoresizingMaskIntoConstraints = false
        let text = UIStackView(arrangedSubviews: [title, meta])
        text.axis = .vertical
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(art)
        contentView.addSubview(text)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            art.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            art.widthAnchor.constraint(equalToConstant: 44),
            art.heightAnchor.constraint(equalToConstant: 44),
            text.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(track: ScreenTrack, number: Int) {
        title.text = track.title
        meta.text = track.artist + " • " + track.album
        artworkLoader.configure(image: track.artwork, url: track.artworkURL)
        accessibilityLabel = "\(track.title), \(track.artist), \(track.album)"
    }
    func loadArtwork() { artworkLoader.load(pointSize: 44) }
    func stopArtwork() { artworkLoader.invalidate() }
    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoader.configure(image: nil, url: nil)
        title.text = nil
        meta.text = nil
    }
}

/// Reference-style track row: star (saved track) left of the number, title column with an
/// optional performer line, and a trailing download-state icon instead of a counter.
private final class AlbumTrackCell: SongSwipeActionCell {
    static let reuseID = "AlbumTrackCell"
    private let star = UIImageView(image: AlbumGlyph.star.image(size: 10))
    private let number = ScreenPalette.label(font: .systemFont(ofSize: 16), color: ScreenPalette.secondary)
    private let title = ScreenPalette.label(font: .systemFont(ofSize: 16))
    private let subtitle = ScreenPalette.label(font: .systemFont(ofSize: 13), color: ScreenPalette.secondary)
    private let download = TrackDownloadIndicator()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        separatorInset = UIEdgeInsets(top: 0, left: 38, bottom: 0, right: 0)
        star.translatesAutoresizingMaskIntoConstraints = false
        star.tintColor = ScreenPalette.secondary
        star.accessibilityIdentifier = "albumTrack.saved"
        star.isAccessibilityElement = true
        star.accessibilityLabel = "Saved track"
        number.textAlignment = .center
        title.lineBreakMode = .byTruncatingTail
        subtitle.accessibilityIdentifier = "albumTrack.subtitle"
        let text = UIStackView(arrangedSubviews: [title, subtitle])
        text.axis = .vertical
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        [star, number, text, download].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            star.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 0),
            star.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            star.widthAnchor.constraint(equalToConstant: 10),
            star.heightAnchor.constraint(equalToConstant: 10),
            number.leadingAnchor.constraint(equalTo: star.trailingAnchor, constant: 1),
            number.widthAnchor.constraint(equalToConstant: 24),
            number.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 38),
            text.trailingAnchor.constraint(equalTo: download.leadingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            download.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            download.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            download.widthAnchor.constraint(equalToConstant: 16),
            download.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(track: ScreenTrack, number: Int, subtitle: String?, isSaved: Bool, download: QobuzDownloadState?) {
        self.number.text = String(number)
        title.text = track.title
        self.subtitle.text = subtitle
        self.subtitle.isHidden = subtitle == nil
        star.isHidden = !isSaved
        star.tintColor = ScreenPalette.secondary
        self.download.configure(download)
        accessibilityLabel = [String(number), track.title, subtitle, isSaved ? "Saved" : nil, self.download.accessibilityLabel]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// Per-track download state that differs by shape, not only color: filled arrow when
/// downloaded, progress ring while downloading/waiting, warning triangle on failure.
private final class TrackDownloadIndicator: UIView {
    private let icon = UIImageView()
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "albumTrack.download"
        isAccessibilityElement = true
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        for layer in [track, ring] {
            layer.fillColor = UIColor.clear.cgColor
            layer.lineWidth = 2
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor),
            icon.topAnchor.constraint(equalTo: topAnchor),
            icon.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = UIBezierPath(arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: bounds.width / 2 - 1.5,
                                startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        ring.path = path.cgPath
        track.path = path.cgPath
    }

    func configure(_ state: QobuzDownloadState?) {
        icon.image = nil
        ring.isHidden = true
        track.isHidden = true
        isHidden = false
        switch state {
        case nil, .notDownloaded?, .cancelled?:
            isHidden = true
            accessibilityLabel = nil
        case .downloaded?:
            icon.image = AlbumGlyph.downloaded.image(size: 16)
            icon.tintColor = ScreenPalette.secondary
            accessibilityLabel = "Downloaded"
        case .failed?:
            icon.image = AlbumGlyph.warning.image(size: 16)
            icon.tintColor = AlbumActionSheetController.destructiveColor
            accessibilityLabel = "Download failed"
        case .queued?, .resolving?, .downloading?:
            var progress: CGFloat = 0
            if case .downloading(let value)? = state { progress = CGFloat(value) }
            track.isHidden = false
            ring.isHidden = false
            track.strokeColor = ScreenPalette.separator.cgColor
            ring.strokeColor = ScreenPalette.accent.cgColor
            ring.strokeEnd = max(0.04, min(1, progress))
            accessibilityLabel = progress > 0 ? "Downloading, \(Int(progress * 100)) percent" : "Waiting to download"
        }
    }
}

private final class ProfileHeader: UIView {
    private let portrait = ArtworkView(image: nil, cornerRadius: 36)
    private lazy var artworkLoader = DetailArtworkLoader(artworkView: portrait)
    private let title = ScreenPalette.label(font: .systemFont(ofSize: 27, weight: .bold), lines: 2)
    private let stats = ScreenPalette.label(font: .systemFont(ofSize: 16), color: ScreenPalette.secondary, lines: 2)
    private let info = ScreenPalette.label(font: .systemFont(ofSize: 15), color: ScreenPalette.secondary, lines: 2)

    init(profile: ScreenProfile) {
        super.init(frame: .zero)
        accessibilityIdentifier = "profileDetail.header"
        [portrait, title, stats, info].forEach(addSubview)
        title.textAlignment = .center
        stats.textAlignment = .center
        info.textAlignment = .center
        title.text = profile.name
        stats.text = profile.subtitle
        info.text = profile.information
        artworkLoader.configure(image: profile.artwork, url: profile.artworkURL)
        artworkLoader.load(pointSize: 72)
        NSLayoutConstraint.activate([
            portrait.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            portrait.centerXAnchor.constraint(equalTo: centerXAnchor),
            portrait.widthAnchor.constraint(equalToConstant: 72),
            portrait.heightAnchor.constraint(equalTo: portrait.widthAnchor),
            title.topAnchor.constraint(equalTo: portrait.bottomAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stats.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            stats.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stats.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            info.topAnchor.constraint(equalTo: stats.bottomAnchor, constant: 9),
            info.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            info.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            info.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ProfileAlbumRowCell: UITableViewCell {
    static let reuseID = "ProfileAlbumRow"
    private let firstCard = ProfileAlbumCard()
    private let secondCard = ProfileAlbumCard()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = DesignSystem.pageBackground
        let row = UIStackView(arrangedSubviews: [firstCard, secondCard])
        row.spacing = 16
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        firstCard.configure(nil, onSelected: nil, onQueueRequested: nil)
        secondCard.configure(nil, onSelected: nil, onQueueRequested: nil)
    }

    func configure(first: ScreenAlbum, second: ScreenAlbum?, onSelected: @escaping (ScreenAlbum) -> Void, onQueueRequested: @escaping (ScreenAlbum) -> Void) {
        firstCard.configure(first, onSelected: onSelected, onQueueRequested: onQueueRequested)
        secondCard.configure(second, onSelected: onSelected, onQueueRequested: onQueueRequested)
    }
}

private final class ProfileAlbumCard: UIView {
    private let art = ArtworkView(image: nil, cornerRadius: DesignSystem.albumArtworkCornerRadius)
    private lazy var artworkLoader = DetailArtworkLoader(artworkView: art)
    private let title = ScreenPalette.label(font: .systemFont(ofSize: 16, weight: .semibold))
    private let meta = ScreenPalette.label(font: .systemFont(ofSize: 13), color: ScreenPalette.secondary)
    private var album: ScreenAlbum?
    private var onSelected: ((ScreenAlbum) -> Void)?
    private var onQueueRequested: ((ScreenAlbum) -> Void)?

    init() {
        super.init(frame: .zero)
        let stack = UIStackView(arrangedSubviews: [art, title, meta])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            art.heightAnchor.constraint(equalTo: art.widthAnchor)
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(selected))
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.45
        tap.require(toFail: longPress)
        addGestureRecognizer(tap)
        addGestureRecognizer(longPress)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        artworkLoader.load(pointSize: bounds.width)
    }

    func configure(_ album: ScreenAlbum?, onSelected: ((ScreenAlbum) -> Void)?, onQueueRequested: ((ScreenAlbum) -> Void)?) {
        self.album = album
        self.onSelected = onSelected
        self.onQueueRequested = onQueueRequested
        // Keep an empty second slot in odd rows, so the first card stays half-width.
        alpha = album == nil ? 0 : 1
        isUserInteractionEnabled = album != nil
        accessibilityElementsHidden = album == nil
        title.text = album?.title
        let metadata = [album?.year ?? "", album.flatMap { $0.tracks.isEmpty ? nil : "\($0.tracks.count) tracks" } ?? ""]
        meta.text = metadata.filter { !$0.isEmpty }.joined(separator: " · ")
        accessibilityLabel = album.map { "\($0.title), \($0.artist)" }
        artworkLoader.configure(image: album?.artwork, url: album?.artworkURL)
        // Bounds are final after layout; do not guess a cache size from screen width.
        setNeedsLayout()
    }

    @objc private func selected() {
        guard let album = album else { return }
        onSelected?(album)
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, let album = album else { return }
        onQueueRequested?(album)
    }

    override func accessibilityActivate() -> Bool {
        guard album != nil else { return false }
        selected()
        return true
    }
}

// Mirrors the pipeline's remote cache key, including the downsampled pixel size.
// Each configuration/size change invalidates old completions, including A → B → A reuse.
final class DetailArtworkLoader {
    private weak var artworkView: ArtworkView?
    private var url: URL?
    private var generation = UUID()
    private var requestedKey: String?

    init(artworkView: ArtworkView) { self.artworkView = artworkView }

    func configure(image: UIImage?, url: URL?) {
        generation = UUID()
        requestedKey = nil
        self.url = url
        artworkView?.image = image
    }

    func invalidate() { generation = UUID(); requestedKey = nil }

    func load(pointSize: CGFloat) {
        guard pointSize > 0, let url = url else { return }
        let pixelSize = max(1, Int(ceil(pointSize * UIScreen.main.scale)))
        let key = "remote|\(url.absoluteString)|\(pixelSize)"
        guard requestedKey != key else { return }
        generation = UUID()
        requestedKey = key
        if let image = ArtworkImagePipeline.shared.cachedImage(for: key) {
            artworkView?.image = image
            return
        }
        let generation = self.generation
        ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: pixelSize) { [weak self] image in
            // The pipeline delivers every completion on the main queue.
            guard let self = self, self.generation == generation,
                  self.requestedKey == key, self.url == url, let image = image else { return }
            self.artworkView?.image = image
        }
    }
}

private var controlClosureKey: UInt8 = 0
private extension UIControl { func addActionCompat(_ block: @escaping () -> Void) { let target = ClosureTarget(block); addTarget(target, action: #selector(ClosureTarget.invoke), for: .touchUpInside); objc_setAssociatedObject(self, &controlClosureKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) } }
private final class ClosureTarget: NSObject { let block: () -> Void; init(_ block: @escaping () -> Void) { self.block = block }; @objc func invoke() { block() } }
