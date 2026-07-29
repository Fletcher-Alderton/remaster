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
    init(album: ScreenAlbum, onArtist: @escaping () -> Void, onPlay: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        accessibilityIdentifier = "albumDetail.header"
        backgroundColor = DesignSystem.pageBackground

        let art = ArtworkView(image: album.artwork, cornerRadius: DesignSystem.albumArtworkCornerRadius)
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

final class ProfileDetailViewController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate, UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate {
    var profile: ScreenProfile { didSet { collection.reloadData() } }
    var onAlbumSelected: ((ScreenAlbum) -> Void)?
    var onAlbumQueueRequested: ((ScreenAlbum) -> Void)?
    var onDismissSwipe: (() -> Void)?
    private let collection: UICollectionView
    private lazy var albumLongPress = UILongPressGestureRecognizer(target: self, action: #selector(albumLongPressed(_:)))
    init(profile: ScreenProfile) {
        self.profile = profile
        let flow = UICollectionViewFlowLayout()
        flow.minimumInteritemSpacing = 16
        flow.minimumLineSpacing = 24
        flow.sectionInset = UIEdgeInsets(top: 14, left: 14, bottom: 90, right: 14)
        flow.headerReferenceSize = CGSize(width: DesignSystem.screenWidth, height: 236)
        collection = UICollectionView(frame: .zero, collectionViewLayout: flow)
        super.init(nibName: nil, bundle: nil)
        modalPresentationCapturesStatusBarAppearance = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { return true }
    override func viewDidLoad() {
        super.viewDidLoad(); view.accessibilityIdentifier = "profileDetail"; view.backgroundColor = DesignSystem.pageBackground
        collection.translatesAutoresizingMaskIntoConstraints = false
        collection.backgroundColor = DesignSystem.pageBackground
        collection.alwaysBounceVertical = true
        collection.dataSource = self
        collection.delegate = self
        collection.register(AlbumCardCellReuse.self, forCellWithReuseIdentifier: AlbumCardCellReuse.id)
        collection.register(ProfileCollectionHeader.self, forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader, withReuseIdentifier: ProfileCollectionHeader.id)
        albumLongPress.minimumPressDuration = 0.45
        collection.addGestureRecognizer(albumLongPress)
        view.addSubview(collection)
        NSLayoutConstraint.activate([
            collection.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collection.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collection.topAnchor.constraint(equalTo: view.topAnchor),
            collection.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        let dismissGesture = UISwipeGestureRecognizer(target: self, action: #selector(dismissSwipe(_:)))
        dismissGesture.direction = .down
        dismissGesture.delegate = self
        view.addGestureRecognizer(dismissGesture)
    }
    @objc private func dismissSwipe(_ recognizer: UISwipeGestureRecognizer) {
        let topOffset = -collection.adjustedContentInset.top
        guard collection.contentOffset.y <= topOffset + 1 else { return }
        onDismissSwipe?()
    }
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { return true }
    @objc private func albumLongPressed(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let indexPath = collection.indexPathForItem(at: gesture.location(in: collection)),
              profile.albums.indices.contains(indexPath.item) else { return }
        onAlbumQueueRequested?(profile.albums[indexPath.item])
    }
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { return profile.albums.count }
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: ProfileCollectionHeader.id, for: indexPath) as! ProfileCollectionHeader
        header.configure(profile)
        return header
    }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell { let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AlbumCardCellReuse.id, for: indexPath) as! AlbumCardCellReuse; cell.configure(profile.albums[indexPath.item]); return cell }
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { onAlbumSelected?(profile.albums[indexPath.item]) }
    func collectionView(_ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath) { if let cell = collectionView.cellForItem(at: indexPath) { InteractionMotion.setRow(cell, highlighted: true) } }
    func collectionView(_ collectionView: UICollectionView, didUnhighlightItemAt indexPath: IndexPath) { if let cell = collectionView.cellForItem(at: indexPath) { InteractionMotion.setRow(cell, highlighted: false) } }
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize { let w = floor((collectionView.bounds.width - 44) / 2); return CGSize(width: w, height: w + 46) }
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

private final class ProfileCollectionHeader: UICollectionReusableView {
    static let id = "ProfileCollectionHeader"
    private let portrait = ArtworkView(image: nil, cornerRadius: 36)
    private let title = ScreenPalette.label(font: .systemFont(ofSize: 27, weight: .bold))
    private let stats = ScreenPalette.label(font: .systemFont(ofSize: 16), color: ScreenPalette.secondary)
    private let info = ScreenPalette.label(font: .systemFont(ofSize: 15), color: ScreenPalette.secondary, lines: 2)
    private let albums = ScreenPalette.label("Albums", font: .systemFont(ofSize: 23, weight: .bold))

    override init(frame: CGRect) {
        super.init(frame: frame)
        [portrait, title, stats, info, albums].forEach(addSubview)
        title.textAlignment = .center
        stats.textAlignment = .center
        info.textAlignment = .center
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
            albums.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            albums.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ profile: ScreenProfile) {
        portrait.image = profile.artwork
        title.text = profile.name
        stats.text = profile.subtitle
        info.text = profile.information
    }
}

private final class AlbumCardCellReuse: UICollectionViewCell {
    static let id = "ProfileAlbumCard"
    private let art = ArtworkView(image: nil, cornerRadius: DesignSystem.albumArtworkCornerRadius)
    private let title = ScreenPalette.label(font: .systemFont(ofSize: 16, weight: .semibold))
    private let meta = ScreenPalette.label(font: .systemFont(ofSize: 13), color: ScreenPalette.secondary)
    override init(frame: CGRect) { super.init(frame: frame); let stack = UIStackView(arrangedSubviews: [art,title,meta]); stack.axis = .vertical; stack.spacing = 4; stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack); NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),stack.topAnchor.constraint(equalTo: contentView.topAnchor),art.heightAnchor.constraint(equalTo: art.widthAnchor)]) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ item: ScreenAlbum) { art.image = item.artwork; title.text = item.title; meta.text = item.year + " · " + String(item.tracks.count) + " tracks" }
}

private var controlClosureKey: UInt8 = 0
private extension UIControl { func addActionCompat(_ block: @escaping () -> Void) { let target = ClosureTarget(block); addTarget(target, action: #selector(ClosureTarget.invoke), for: .touchUpInside); objc_setAssociatedObject(self, &controlClosureKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) } }
private final class ClosureTarget: NSObject { let block: () -> Void; init(_ block: @escaping () -> Void) { self.block = block }; @objc func invoke() { block() } }
