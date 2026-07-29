import UIKit

final class LibraryViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UICollectionViewDataSource, UICollectionViewDelegate, UISearchBarDelegate, UIGestureRecognizerDelegate {
    let kind: LibraryScreenKind
    var tracks: [ScreenTrack] = [] { didSet { refreshContentIfLoaded() } }
    var albums: [ScreenAlbum] = [] { didSet { refreshContentIfLoaded() } }
    var profiles: [ScreenProfile] = [] { didSet { refreshContentIfLoaded() } }
    var playlists: [ScreenPlaylist] = [] { didSet { refreshContentIfLoaded() } }
    var onTrackListSelected: (([ScreenTrack], Int) -> Void)?
    var onTrackNavigationRequested: ((ScreenTrack) -> Void)?
    var onAlbumSelected: ((ScreenAlbum) -> Void)?
    var onAlbumQueueRequested: ((ScreenAlbum) -> Void)?
    var onProfileSelected: ((ScreenProfile) -> Void)?
    var onSongSwipeAction: ((ScreenTrack, SongSwipeAction) -> Void)?
    var onTabSwipe: ((Bool) -> Void)? // true is forward

    private var filteredTracks: [ScreenTrack] = []
    private var filteredAlbums: [ScreenAlbum] = []
    private var filteredProfiles: [ScreenProfile] = []
    private var filteredPlaylists: [ScreenPlaylist] = []
    private let tools = UIView()
    private let search = UISearchBar()
    private let filter = UISegmentedControl(items: ["All", "A–Z", "Z–A"])
    private var toolsHeight: NSLayoutConstraint!
    private let table = UITableView(frame: .zero, style: .plain)
    private var collection: UICollectionView!
    private var showingTools = false
    private lazy var pullPan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
    private lazy var previousTabPan = UIPanGestureRecognizer(target: self, action: #selector(previousTabEdgePan(_:)))
    private lazy var nextTabPan = UIPanGestureRecognizer(target: self, action: #selector(nextTabEdgePan(_:)))
    private lazy var albumLongPress = UILongPressGestureRecognizer(target: self, action: #selector(albumLongPressed(_:)))
    private var songSwipeCoordinator: SongListSwipeCoordinator?

    init(kind: LibraryScreenKind) { self.kind = kind; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "library.\(kind.rawValue)"
        view.backgroundColor = DesignSystem.pageBackground
        buildTools(); buildList()
        pullPan.cancelsTouchesInView = false
        pullPan.delegate = self
        view.addGestureRecognizer(pullPan)
        previousTabPan.delegate = self
        nextTabPan.delegate = self
        previousTabPan.cancelsTouchesInView = false
        nextTabPan.cancelsTouchesInView = false
        view.addGestureRecognizer(previousTabPan)
        view.addGestureRecognizer(nextTabPan)
        applyFilters()
    }

    private func buildTools() {
        tools.translatesAutoresizingMaskIntoConstraints = false; tools.clipsToBounds = true
        tools.accessibilityIdentifier = "libraryTools.\(kind.rawValue)"
        search.translatesAutoresizingMaskIntoConstraints = false; search.delegate = self
        search.searchBarStyle = .minimal; search.placeholder = kind.searchPlaceholder
        search.accessibilityIdentifier = "librarySearch.\(kind.rawValue)"
        filter.translatesAutoresizingMaskIntoConstraints = false; filter.selectedSegmentIndex = 0
        filter.accessibilityIdentifier = "libraryFilter.\(kind.rawValue)"
        filter.tintColor = ScreenPalette.accent; filter.addTarget(self, action: #selector(filterChanged), for: .valueChanged)
        tools.addSubview(search); tools.addSubview(filter); view.addSubview(tools)
        toolsHeight = tools.heightAnchor.constraint(equalToConstant: 0); toolsHeight.isActive = true
        NSLayoutConstraint.activate([
            tools.leadingAnchor.constraint(equalTo: view.leadingAnchor), tools.trailingAnchor.constraint(equalTo: view.trailingAnchor), tools.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            search.leadingAnchor.constraint(equalTo: tools.leadingAnchor, constant: 12), search.topAnchor.constraint(equalTo: tools.topAnchor, constant: 4), search.bottomAnchor.constraint(equalTo: tools.bottomAnchor, constant: -4),
            filter.trailingAnchor.constraint(equalTo: tools.trailingAnchor, constant: -14), filter.centerYAnchor.constraint(equalTo: search.centerYAnchor), filter.widthAnchor.constraint(equalToConstant: 112),
            search.trailingAnchor.constraint(equalTo: filter.leadingAnchor, constant: -6)
        ])
    }

    private func buildList() {
        if kind == .albums {
            let layout = UICollectionViewFlowLayout(); layout.minimumLineSpacing = 28; layout.minimumInteritemSpacing = 16
            layout.sectionInset = UIEdgeInsets(top: 18, left: 14, bottom: 102, right: 14)
            collection = UICollectionView(frame: .zero, collectionViewLayout: layout)
            collection.translatesAutoresizingMaskIntoConstraints = false; collection.backgroundColor = DesignSystem.pageBackground
            collection.dataSource = self; collection.delegate = self
            collection.register(LibraryScreenAlbumCardCell.self, forCellWithReuseIdentifier: LibraryScreenAlbumCardCell.reuseID)
            albumLongPress.minimumPressDuration = 0.45
            collection.addGestureRecognizer(albumLongPress)
            view.addSubview(collection)
            NSLayoutConstraint.activate([collection.leadingAnchor.constraint(equalTo: view.leadingAnchor), collection.trailingAnchor.constraint(equalTo: view.trailingAnchor), collection.topAnchor.constraint(equalTo: tools.bottomAnchor), collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        } else {
            table.translatesAutoresizingMaskIntoConstraints = false; table.backgroundColor = DesignSystem.pageBackground; table.separatorColor = ScreenPalette.separator
            table.dataSource = self; table.delegate = self; table.rowHeight = 78; table.keyboardDismissMode = .onDrag
            let miniPlayerClearance = DesignSystem.miniPlayerHeight + 14
            table.contentInset.bottom = miniPlayerClearance
            table.scrollIndicatorInsets.bottom = miniPlayerClearance
            table.register(LibraryScreenRowCell.self, forCellReuseIdentifier: LibraryScreenRowCell.reuseID)
            view.addSubview(table)
            NSLayoutConstraint.activate([table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10), table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10), table.topAnchor.constraint(equalTo: tools.bottomAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
            if kind == .tracks { songSwipeCoordinator = SongListSwipeCoordinator(tableView: table) }
        }
    }

    private func applyFilters() {
        let query = (search.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func matches(_ values: String...) -> Bool { return query.isEmpty || values.joined(separator: " ").lowercased().contains(query) }
        switch kind {
        case .tracks:
            filteredTracks = tracks.filter { matches($0.title, $0.artist, $0.album) }
            if filter.selectedSegmentIndex == 1 { filteredTracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
            if filter.selectedSegmentIndex == 2 { filteredTracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending } }
        case .albums:
            filteredAlbums = albums.filter { matches($0.title, $0.artist, $0.year) }
            if filter.selectedSegmentIndex == 1 { filteredAlbums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }
            if filter.selectedSegmentIndex == 2 { filteredAlbums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending } }
        case .artists, .genres:
            filteredProfiles = profiles.filter { matches($0.name, $0.subtitle) }
            if filter.selectedSegmentIndex == 1 { filteredProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
            if filter.selectedSegmentIndex == 2 { filteredProfiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending } }
        case .playlists:
            filteredPlaylists = playlists.filter { matches($0.name) }
            if filter.selectedSegmentIndex == 1 { filteredPlaylists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }
            if filter.selectedSegmentIndex == 2 { filteredPlaylists.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending } }
        }
        if kind == .playlists && filteredPlaylists.isEmpty {
            let empty = EmptyStateView()
            empty.configure(title: "No local playlists.")
            table.backgroundView = empty
        } else if kind != .albums {
            table.backgroundView = nil
        }
        table.reloadData(); collection?.reloadData()
    }

    private func refreshContentIfLoaded() {
        guard isViewLoaded else { return }
        applyFilters()
    }

    @objc private func filterChanged() { applyFilters() }
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { applyFilters() }

    private func setToolsVisible(_ visible: Bool, animated: Bool = true) {
        guard showingTools != visible else { return }; showingTools = visible; toolsHeight.constant = visible ? 52 : 0
        let block = { self.view.layoutIfNeeded() }
        if animated {
            UIView.animate(
                withDuration: InteractionMotion.quick,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
                animations: block
            )
        } else {
            block()
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        let offset = collection?.contentOffset.y ?? table.contentOffset.y
        let atTop = offset <= 1
        if translation.y > 30 && atTop { setToolsVisible(true) }
        else if translation.y < -20 && showingTools { setToolsVisible(false) }
        else if velocity.y < -240 && showingTools { setToolsVisible(false) }
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: view) ?? .zero
        if gestureRecognizer === previousTabPan { return velocity.x > abs(velocity.y) }
        if gestureRecognizer === nextTabPan { return -velocity.x > abs(velocity.y) }
        if gestureRecognizer === pullPan { return abs(velocity.y) > abs(velocity.x) }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === previousTabPan || gestureRecognizer === nextTabPan else { return true }
        guard let window = touch.window else { return false }
        let x = touch.location(in: window).x
        if gestureRecognizer === previousTabPan { return x <= 24 }
        return x >= window.bounds.width - 24
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return gestureRecognizer === pullPan || otherGestureRecognizer === pullPan
    }

    @objc private func previousTabEdgePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, gesture.translation(in: view).x > 45 else { return }
        onTabSwipe?(false)
    }

    @objc private func nextTabEdgePan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, gesture.translation(in: view).x < -45 else { return }
        onTabSwipe?(true)
    }

    @objc private func albumLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let indexPath = collection.indexPathForItem(at: gesture.location(in: collection)),
              filteredAlbums.indices.contains(indexPath.item) else { return }
        onAlbumQueueRequested?(filteredAlbums[indexPath.item])
    }

    func numberOfSections(in tableView: UITableView) -> Int { return 1 }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch kind { case .tracks: return filteredTracks.count; case .artists, .genres: return filteredProfiles.count; case .playlists: return filteredPlaylists.count; case .albums: return 0 }
    }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LibraryScreenRowCell.reuseID, for: indexPath) as! LibraryScreenRowCell
        cell.accessibilityIdentifier = "libraryRow.\(indexPath.row)"
        switch kind {
        case .tracks:
            let item = filteredTracks[indexPath.row]
            cell.configure(title: item.title, subtitle: item.artist + " · " + item.album, image: item.artwork)
            cell.onSwipeAction = { [weak self] action in self?.onSongSwipeAction?(item, action) }
            cell.onLongPress = { [weak self] in self?.onTrackNavigationRequested?(item) }
        case .artists:
            let item = filteredProfiles[indexPath.row]
            cell.configure(title: item.name, subtitle: nil, image: item.artwork, rounded: true)
        case .genres:
            let item = filteredProfiles[indexPath.row]
            cell.configure(title: item.name, subtitle: item.subtitle, image: item.artwork, rounded: true)
        case .playlists: let item = filteredPlaylists[indexPath.row]; cell.configure(title: item.name, subtitle: "\(item.trackCount) tracks", image: item.artwork)
        case .albums: break
        }
        return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch kind {
        case .tracks:
            onTrackListSelected?(filteredTracks, indexPath.row)
        case .artists, .genres:
            onProfileSelected?(filteredProfiles[indexPath.row])
        default:
            break
        }
    }
    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        if let cell = tableView.cellForRow(at: indexPath) { InteractionMotion.setRow(cell, highlighted: true) }
    }
    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        if let cell = tableView.cellForRow(at: indexPath) { InteractionMotion.setRow(cell, highlighted: false) }
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { return filteredAlbums.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let cell = collectionView.dequeueReusableCell(withReuseIdentifier: LibraryScreenAlbumCardCell.reuseID, for: indexPath) as! LibraryScreenAlbumCardCell; cell.accessibilityIdentifier = "albumCard.\(indexPath.item)"; cell.configure(filteredAlbums[indexPath.item]); return cell }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { onAlbumSelected?(filteredAlbums[indexPath.item]) }
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) { InteractionMotion.setRow(cell, highlighted: true) }
    }
    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) {
        if let cell = collectionView.cellForItem(at: indexPath) { InteractionMotion.setRow(cell, highlighted: false) }
    }
}

extension LibraryViewController: UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize {
        let width = floor((collectionView.bounds.width - 44) / 2); return CGSize(width: width, height: width + 50)
    }
}

private final class LibraryScreenRowCell: SongSwipeActionCell {
    static let reuseID = "LibraryRowCell"; private let art = ArtworkView(image: nil, cornerRadius: DesignSystem.albumArtworkCornerRadius); private let title = ScreenPalette.label(font: .systemFont(ofSize: 18)); private let subtitle = ScreenPalette.label(font: .systemFont(ofSize: 14), color: ScreenPalette.secondary)
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) { super.init(style: style, reuseIdentifier: reuseIdentifier); backgroundColor = DesignSystem.pageBackground; contentView.backgroundColor = DesignSystem.pageBackground; selectionStyle = .none
        let labels = UIStackView(arrangedSubviews: [title, subtitle]); labels.axis = .vertical; labels.spacing = 3; labels.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(art); contentView.addSubview(labels)
        NSLayoutConstraint.activate([art.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8), art.centerYAnchor.constraint(equalTo: contentView.centerYAnchor), art.widthAnchor.constraint(equalToConstant: 54), art.heightAnchor.constraint(equalToConstant: 54), labels.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 14), labels.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12), labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(title: String, subtitle: String?, image: UIImage?, rounded: Bool = false) {
        self.title.text = title
        self.subtitle.text = subtitle
        self.subtitle.isHidden = subtitle == nil
        art.image = image
        art.layer.cornerRadius = rounded ? 27 : DesignSystem.albumArtworkCornerRadius
    }
}

private final class LibraryScreenAlbumCardCell: UICollectionViewCell {
    static let reuseID = "AlbumCardCell"; private let art = ArtworkView(image: nil, cornerRadius: DesignSystem.albumArtworkCornerRadius); private let title = ScreenPalette.label(font: .systemFont(ofSize: 17, weight: .semibold)); private let meta = ScreenPalette.label(font: .systemFont(ofSize: 14), color: ScreenPalette.secondary)
    override init(frame: CGRect) { super.init(frame: frame); let stack = UIStackView(arrangedSubviews: [art, title, meta]); stack.axis = .vertical; stack.spacing = 5; stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor), stack.topAnchor.constraint(equalTo: contentView.topAnchor), art.heightAnchor.constraint(equalTo: art.widthAnchor)]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ album: ScreenAlbum) { art.image = album.artwork; title.text = album.title; meta.text = album.artist + (album.year.isEmpty ? "" : " · " + album.year) }
}
