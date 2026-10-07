import UIKit

final class AlbumDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    var album: ScreenAlbum { didSet { reload() } }
    var onTrackSelected: ((ScreenTrack) -> Void)?
    var onTrackNavigationRequested: ((ScreenTrack) -> Void)?
    var onSongSwipeAction: ((ScreenTrack, SongSwipeAction) -> Void)?
    var onArtistSelected: ((String) -> Void)?
    var onAlbumQueueRequested: ((ScreenAlbum) -> Void)?
    var onDismissSwipe: (() -> Void)?
    var onPlayAlbum: (([ScreenTrack], Bool) -> Void)?
    private let table = UITableView(frame: .zero, style: .plain)
    private var songSwipeCoordinator: SongListSwipeCoordinator?
    private let headerHeight: CGFloat = 224

    init(album: ScreenAlbum) {
        self.album = album
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { return true }
    override func viewDidLoad() {
        super.viewDidLoad(); view.accessibilityIdentifier = "albumDetail"; view.backgroundColor = DesignSystem.pageBackground
        table.backgroundColor = DesignSystem.pageBackground
        table.translatesAutoresizingMaskIntoConstraints = false; table.dataSource = self; table.delegate = self; table.rowHeight = 62; table.separatorColor = ScreenPalette.separator
        table.showsVerticalScrollIndicator = false
        table.register(AlbumTrackCell.self, forCellReuseIdentifier: AlbumTrackCell.reuseID)
        table.tableHeaderView = makeHeader()
        view.addSubview(table)
        songSwipeCoordinator = SongListSwipeCoordinator(tableView: table)
        NSLayoutConstraint.activate([table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12), table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12), table.topAnchor.constraint(equalTo: view.topAnchor), table.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        let dismissGesture = UISwipeGestureRecognizer(target: self, action: #selector(dismissSwipe(_:)))
        dismissGesture.direction = .down
        dismissGesture.delegate = self
        view.addGestureRecognizer(dismissGesture)
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = table.tableHeaderView,
              header.frame.width != table.bounds.width else { return }
        header.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: headerHeight)
        table.tableHeaderView = header
    }
    private func makeHeader() -> UIView {
        let header = AlbumHeader(
            album: album,
            onArtist: { [weak self] in self?.onArtistSelected?(self?.album.artist ?? "") },
            onPlay: { [weak self] shuffle in
                guard let self = self else { return }
                self.onPlayAlbum?(self.album.tracks, shuffle)
            }
        )
        header.frame = CGRect(x: 0, y: 0, width: max(table.bounds.width, 296), height: headerHeight)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(albumHeaderLongPressed(_:)))
        longPress.minimumPressDuration = 0.45
        header.addGestureRecognizer(longPress)
        return header
    }
    private func reload() {
        guard isViewLoaded else { return }
        table.tableHeaderView = makeHeader()
        table.reloadData()
    }
    @objc private func dismissSwipe(_ recognizer: UISwipeGestureRecognizer) {
        let topOffset = -table.adjustedContentInset.top
        guard table.contentOffset.y <= topOffset + 1 else { return }
        onDismissSwipe?()
    }
    @objc private func albumHeaderLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onAlbumQueueRequested?(album)
    }
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { return true }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return album.tracks.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell { let track = album.tracks[indexPath.row]; let cell = tableView.dequeueReusableCell(withIdentifier: AlbumTrackCell.reuseID, for: indexPath) as! AlbumTrackCell; cell.configure(track: track, number: indexPath.row + 1); cell.onSwipeAction = { [weak self] action in self?.onSongSwipeAction?(track, action) }; cell.onLongPress = { [weak self] in self?.onTrackNavigationRequested?(track) }; return cell }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { tableView.deselectRow(at: indexPath, animated: true); onTrackSelected?(album.tracks[indexPath.row]) }
    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) { if let cell = tableView.cellForRow(at: indexPath) { InteractionMotion.setRow(cell, highlighted: true) } }
    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) { if let cell = tableView.cellForRow(at: indexPath) { InteractionMotion.setRow(cell, highlighted: false) } }
}

private final class AlbumHeader: UIView {
    private let art = ArtworkView(image: nil, cornerRadius: DesignSystem.albumArtworkCornerRadius)
    private lazy var artworkLoader = DetailArtworkLoader(artworkView: art)

    init(album: ScreenAlbum, onArtist: @escaping () -> Void, onPlay: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        accessibilityIdentifier = "albumDetail.header"
        backgroundColor = DesignSystem.pageBackground

        artworkLoader.configure(image: album.artwork, url: album.artworkURL)
        artworkLoader.load(pointSize: 102)
        let title = ScreenPalette.label(album.title, font: .systemFont(ofSize: 19, weight: .bold), lines: 2)
        title.accessibilityIdentifier = "albumDetail.title"
        let artist = UIButton(type: .system)
        artist.translatesAutoresizingMaskIntoConstraints = false
        artist.setTitle(album.artist, for: .normal)
        artist.contentHorizontalAlignment = .left
        artist.titleLabel?.font = .systemFont(ofSize: 17)
        artist.tintColor = ScreenPalette.accent
        artist.addActionCompat(onArtist)
        let metadata = [album.genre, album.year].filter { !$0.isEmpty }.joined(separator: " · ")
        let info = ScreenPalette.label(metadata, font: .systemFont(ofSize: 15), color: ScreenPalette.secondary)
        let quality = ScreenPalette.label(album.quality, font: .systemFont(ofSize: 12), color: ScreenPalette.secondary)
        let text = UIStackView(arrangedSubviews: [title, artist, info, quality])
        text.axis = .vertical
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false

        let play = HeaderActionButton(symbol: "▶  Play")
        play.addActionCompat { onPlay(false) }
        let shuffle = HeaderActionButton(title: "Shuffle", image: MusicSymbol.shuffle(size: CGSize(width: 20, height: 20)))
        shuffle.addActionCompat { onPlay(true) }
        let actions = UIStackView(arrangedSubviews: [play, shuffle])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.spacing = 12
        actions.distribution = .fillEqually

        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = ScreenPalette.separator

        addSubview(art)
        addSubview(text)
        addSubview(separator)
        addSubview(actions)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            art.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            art.widthAnchor.constraint(equalToConstant: 102),
            art.heightAnchor.constraint(equalTo: art.widthAnchor),
            text.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.topAnchor.constraint(equalTo: art.topAnchor, constant: 1),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            separator.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 12),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            actions.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            actions.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            actions.heightAnchor.constraint(equalToConstant: 46)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

// A table keeps top tracks on the same swipe/long-press path as album tracks.
// Release rows retain the two-column grid without nesting scroll views.
final class ProfileDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    var profile: ScreenProfile { didSet { reload() } }
    var onAlbumSelected: ((ScreenAlbum) -> Void)?
    var onAlbumQueueRequested: ((ScreenAlbum) -> Void)?
    var onTrackSelected: ((ScreenTrack) -> Void)?
    var onTrackNavigationRequested: ((ScreenTrack) -> Void)?
    var onSongSwipeAction: ((ScreenTrack, SongSwipeAction) -> Void)?
    var onDismissSwipe: (() -> Void)?

    private enum Section { case tracks, albums }
    private var sections: [Section] {
        var result: [Section] = []
        if !profile.tracks.isEmpty { result.append(.tracks) }
        if !profile.albums.isEmpty { result.append(.albums) }
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
        table.register(AlbumTrackCell.self, forCellReuseIdentifier: AlbumTrackCell.reuseID)
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
        case .albums: return (profile.albums.count + 1) / 2
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        let header = UIView()
        header.backgroundColor = DesignSystem.pageBackground
        let label = ScreenPalette.label(sections[section] == .tracks ? "Top Tracks" : "Albums", font: .systemFont(ofSize: 23, weight: .bold))
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
            let cell = tableView.dequeueReusableCell(withIdentifier: AlbumTrackCell.reuseID, for: indexPath) as! AlbumTrackCell
            cell.configure(track: track, number: indexPath.row + 1)
            cell.onSwipeAction = { [weak self] action in self?.onSongSwipeAction?(track, action) }
            cell.onLongPress = { [weak self] in self?.onTrackNavigationRequested?(track) }
            return cell
        case .albums:
            let cell = tableView.dequeueReusableCell(withIdentifier: ProfileAlbumRowCell.reuseID, for: indexPath) as! ProfileAlbumRowCell
            let firstIndex = indexPath.row * 2
            let secondIndex = firstIndex + 1
            cell.configure(
                first: profile.albums[firstIndex],
                second: profile.albums.indices.contains(secondIndex) ? profile.albums[secondIndex] : nil,
                onSelected: { [weak self] in self?.onAlbumSelected?($0) },
                onQueueRequested: { [weak self] in self?.onAlbumQueueRequested?($0) }
            )
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections[indexPath.section] == .tracks else { return }
        onTrackSelected?(profile.tracks[indexPath.row])
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

private final class AlbumTrackCell: SongSwipeActionCell {
    static let reuseID = "AlbumTrackCell"; private let number = ScreenPalette.label(font: .systemFont(ofSize: 16), color: ScreenPalette.secondary); private let title = ScreenPalette.label(font: .systemFont(ofSize: 18)); private let meta = ScreenPalette.label(font: .systemFont(ofSize: 14), color: ScreenPalette.secondary)
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) { super.init(style: style, reuseIdentifier: reuseIdentifier); selectionStyle = .none; let text = UIStackView(arrangedSubviews: [title, meta]); text.axis = .vertical; text.spacing = 2; text.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(number); contentView.addSubview(text); NSLayoutConstraint.activate([number.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10), number.centerYAnchor.constraint(equalTo: contentView.centerYAnchor), number.widthAnchor.constraint(equalToConstant: 25), text.leadingAnchor.constraint(equalTo: number.trailingAnchor, constant: 10), text.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8), text.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(track: ScreenTrack, number: Int) { self.number.text = String(number); title.text = track.title; meta.text = track.artist }
}

private final class HeaderActionButton: UIButton {
    init(symbol: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setTitle(symbol, for: .normal)
        setTitleColor(ScreenPalette.accent, for: .normal)
        titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        backgroundColor = ScreenPalette.softFill
        layer.cornerRadius = 8
    }

    init(title: String, image: UIImage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setTitle(title, for: .normal)
        setImage(image, for: .normal)
        setTitleColor(ScreenPalette.accent, for: .normal)
        tintColor = ScreenPalette.accent
        titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        imageEdgeInsets = UIEdgeInsets(top: 0, left: -4, bottom: 0, right: 4)
        titleEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: -4)
        backgroundColor = ScreenPalette.softFill
        layer.cornerRadius = 8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
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
private final class DetailArtworkLoader {
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
