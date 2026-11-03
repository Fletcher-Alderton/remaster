import UIKit

final class QueueViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    var onSelectTrack: ((Int) -> Void)?
    var onRemoveTrack: ((Int) -> Void)?
    var onMoveTrack: ((Int, Int) -> Void)?
    var onClearQueue: (() -> Void)?
    var onShuffleQueue: (() -> Void)?
    var onDismissSwipe: (() -> Void)?
    var onSongSwipeAction: ((ScreenTrack, SongSwipeAction) -> Void)?
    var onTrackNavigationRequested: ((ScreenTrack) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .plain)
    private var songSwipeCoordinator: SongListSwipeCoordinator?
    private weak var songSwipePan: UIGestureRecognizer?
    private weak var editButton: UIButton?
    private var tracks: [ScreenTrack]
    private var currentIndex: Int
    private var headerArtworkLoader: QueueArtworkLoader?

    init(tracks: [ScreenTrack], currentIndex: Int) {
        self.tracks = tracks
        self.currentIndex = max(0, min(currentIndex, max(0, tracks.count - 1)))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        modalPresentationCapturesStatusBarAppearance = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "queue"
        view.backgroundColor = DesignSystem.pageBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = DesignSystem.pageBackground
        tableView.separatorColor = DesignSystem.separator
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 92, bottom: 0, right: 14)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 82
        tableView.sectionHeaderHeight = 0
        tableView.sectionFooterHeight = 0
        tableView.register(QueueTrackCell.self, forCellReuseIdentifier: QueueTrackCell.reuseIdentifier)
        let existingGestures = tableView.gestureRecognizers ?? []
        songSwipeCoordinator = SongListSwipeCoordinator(tableView: tableView)
        songSwipePan = tableView.gestureRecognizers?.first { gesture in
            !existingGestures.contains(where: { $0 === gesture })
        }
        tableView.tableHeaderView = makeHeader()
        view.addSubview(tableView)
        tableView.pinEdges(to: view)

        let dismiss = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        dismiss.direction = .down
        dismiss.delegate = self
        view.addGestureRecognizer(dismiss)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return true
    }

    func update(tracks: [ScreenTrack], currentIndex: Int) {
        let normalizedIndex = max(0, min(currentIndex, max(0, tracks.count - 1)))
        let structureChanged = self.tracks.map({ $0.id }) != tracks.map({ $0.id })
            || self.currentIndex != normalizedIndex
        let changedIndices = structureChanged ? [] : tracks.indices.filter {
            !self.tracks[$0].hasSamePresentation(as: tracks[$0])
        }
        guard structureChanged || !changedIndices.isEmpty else { return }
        self.tracks = tracks
        self.currentIndex = normalizedIndex
        guard isViewLoaded else { return }
        if structureChanged {
            tableView.tableHeaderView = makeHeader()
            tableView.reloadData()
        } else {
            // Metadata/URL changes with unchanged queue IDs need not reset row
            // swipes or scroll position, and artwork completion never reloads.
            if changedIndices.contains(normalizedIndex) {
                tableView.tableHeaderView = makeHeader()
            }
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                let queueIndex = normalizedIndex + 1 + indexPath.row
                guard changedIndices.contains(queueIndex),
                      let cell = tableView.cellForRow(at: indexPath) as? QueueTrackCell else { continue }
                configure(cell, track: tracks[queueIndex])
                cell.loadArtwork()
            }
        }
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: max(320, view.bounds.width), height: 196))
        header.accessibilityIdentifier = "queue.header"
        let currentTrackLongPress = UILongPressGestureRecognizer(target: self, action: #selector(currentTrackLongPressed(_:)))
        currentTrackLongPress.minimumPressDuration = 0.45
        header.addGestureRecognizer(currentTrackLongPress)
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Now Playing"
        title.font = DesignSystem.font(20, weight: .bold)
        let shuffle = UIButton(type: .system)
        shuffle.translatesAutoresizingMaskIntoConstraints = false
        shuffle.setImage(MusicSymbol.shuffle(), for: .normal)
        shuffle.tintColor = DesignSystem.primaryText
        shuffle.backgroundColor = DesignSystem.controlFill
        shuffle.layer.cornerRadius = 8
        shuffle.accessibilityLabel = "Shuffle queue"
        shuffle.addTarget(self, action: #selector(shuffleTapped), for: .touchUpInside)
        let repeatButton = UIButton(type: .system)
        repeatButton.translatesAutoresizingMaskIntoConstraints = false
        repeatButton.setImage(MusicSymbol.repeatIcon(), for: .normal)
        repeatButton.tintColor = DesignSystem.primaryText
        repeatButton.backgroundColor = DesignSystem.controlFill
        repeatButton.layer.cornerRadius = 8
        repeatButton.accessibilityLabel = "Repeat"

        let current = currentIndex < tracks.count ? tracks[currentIndex] : nil
        let artwork = UIImageView(image: current?.artwork)
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.layer.cornerRadius = DesignSystem.albumArtworkCornerRadius
        artwork.backgroundColor = DesignSystem.controlFill
        let artworkLoader = QueueArtworkLoader(imageView: artwork)
        headerArtworkLoader = artworkLoader
        artworkLoader.configure(current)
        artworkLoader.load(pointSize: 62)
        let trackLabel = UILabel()
        trackLabel.translatesAutoresizingMaskIntoConstraints = false
        trackLabel.text = current?.title ?? "Nothing is playing"
        trackLabel.font = DesignSystem.font(17, weight: .semibold)
        let metaLabel = UILabel()
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.text = current.map { "\($0.artist) · \($0.duration.screenTime)" } ?? ""
        metaLabel.textColor = DesignSystem.secondaryText
        metaLabel.font = DesignSystem.font(14)
        let text = UIStackView(arrangedSubviews: [trackLabel, metaLabel])
        text.translatesAutoresizingMaskIntoConstraints = false
        text.axis = .vertical
        text.spacing = 4
        let indicator = QueuePlayingIndicator()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        let separator = UIView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.backgroundColor = DesignSystem.separator
        let upNextTitle = UILabel()
        upNextTitle.translatesAutoresizingMaskIntoConstraints = false
        upNextTitle.text = "Up Next"
        upNextTitle.font = DesignSystem.font(20, weight: .bold)
        upNextTitle.textColor = DesignSystem.primaryText
        let clear = UIButton(type: .system)
        clear.translatesAutoresizingMaskIntoConstraints = false
        clear.setTitle("Clear Queue", for: .normal)
        clear.setTitleColor(DesignSystem.accent, for: .normal)
        clear.titleLabel?.font = DesignSystem.font(15, weight: .medium)
        clear.addTarget(self, action: #selector(clearTapped), for: .touchUpInside)
        clear.isHidden = numberOfUpcomingTracks == 0
        let edit = UIButton(type: .system)
        edit.translatesAutoresizingMaskIntoConstraints = false
        edit.setTitle(tableView.isEditing ? "Done" : "Edit", for: .normal)
        edit.setTitleColor(DesignSystem.accent, for: .normal)
        edit.titleLabel?.font = DesignSystem.font(15, weight: .medium)
        edit.accessibilityIdentifier = "queue.edit"
        edit.accessibilityLabel = tableView.isEditing ? "Done editing queue" : "Edit queue"
        edit.addTarget(self, action: #selector(editTapped), for: .touchUpInside)
        editButton = edit
        header.addSubview(title)
        header.addSubview(shuffle)
        header.addSubview(repeatButton)
        header.addSubview(artwork)
        header.addSubview(text)
        header.addSubview(indicator)
        header.addSubview(separator)
        header.addSubview(upNextTitle)
        header.addSubview(clear)
        header.addSubview(edit)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: header.topAnchor, constant: 14),
            shuffle.trailingAnchor.constraint(equalTo: repeatButton.leadingAnchor, constant: -7),
            shuffle.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            shuffle.widthAnchor.constraint(equalToConstant: 38),
            shuffle.heightAnchor.constraint(equalToConstant: 32),
            repeatButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            repeatButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            repeatButton.widthAnchor.constraint(equalToConstant: 38),
            repeatButton.heightAnchor.constraint(equalToConstant: 32),
            artwork.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            artwork.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            artwork.widthAnchor.constraint(equalToConstant: 62),
            artwork.heightAnchor.constraint(equalToConstant: 62),
            text.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: indicator.leadingAnchor, constant: -10),
            text.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            indicator.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -17),
            indicator.centerYAnchor.constraint(equalTo: artwork.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 18),
            indicator.heightAnchor.constraint(equalToConstant: 20),
            separator.leadingAnchor.constraint(equalTo: text.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            separator.topAnchor.constraint(equalTo: artwork.bottomAnchor, constant: 12),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            upNextTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            upNextTitle.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -10),
            upNextTitle.trailingAnchor.constraint(lessThanOrEqualTo: clear.leadingAnchor, constant: -8),
            clear.trailingAnchor.constraint(equalTo: edit.leadingAnchor, constant: -12),
            clear.centerYAnchor.constraint(equalTo: upNextTitle.centerYAnchor),
            edit.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            edit.centerYAnchor.constraint(equalTo: upNextTitle.centerYAnchor),
            edit.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            edit.heightAnchor.constraint(equalToConstant: 44)
        ])
        InteractionMotion.install(in: header)
        return header
    }

    func numberOfSections(in tableView: UITableView) -> Int { return 1 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(0, tracks.count - currentIndex - 1)
    }

    private var numberOfUpcomingTracks: Int {
        return max(0, tracks.count - currentIndex - 1)
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let queueIndex = currentIndex + 1 + indexPath.row
        let track = tracks[queueIndex]
        let cell = tableView.dequeueReusableCell(withIdentifier: QueueTrackCell.reuseIdentifier, for: indexPath) as! QueueTrackCell
        configure(cell, track: track)
        return cell
    }

    private func configure(_ cell: QueueTrackCell, track: ScreenTrack) {
        cell.configure(track)
        cell.onSwipeAction = { [weak self] action in self?.onSongSwipeAction?(track, action) }
        cell.onLongPress = { [weak self] in self?.onTrackNavigationRequested?(track) }
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let queueIndex = currentIndex + 1 + indexPath.row
        guard tracks.indices.contains(queueIndex), let cell = cell as? QueueTrackCell else { return }
        // A prefetched/offscreen cell may predate a metadata-only update.
        configure(cell, track: tracks[queueIndex])
        cell.loadArtwork()
    }

    func tableView(_ tableView: UITableView, didEndDisplaying cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        (cell as? QueueTrackCell)?.cancelArtwork()
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        return onRemoveTrack != nil
    }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete else { return }
        onRemoveTrack?(currentIndex + 1 + indexPath.row)
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return onMoveTrack != nil
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        onMoveTrack?(currentIndex + 1 + sourceIndexPath.row, currentIndex + 1 + destinationIndexPath.row)
    }

    func setQueueEditing(_ editing: Bool) {
        loadViewIfNeeded()
        // The coordinator installs one pan but exposes no enable/disable API.
        // Disable its recognizer, not the table's scrolling/reordering gestures.
        songSwipePan?.isEnabled = !editing
        tableView.setEditing(editing, animated: true)
        editButton?.setTitle(editing ? "Done" : "Edit", for: .normal)
        editButton?.accessibilityLabel = editing ? "Done editing queue" : "Edit queue"
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelectTrack?(currentIndex + 1 + indexPath.row)
    }

    func tableView(_ tableView: UITableView, didHighlightRowAt indexPath: IndexPath) {
        if let cell = tableView.cellForRow(at: indexPath) { InteractionMotion.setRow(cell, highlighted: true) }
    }

    func tableView(_ tableView: UITableView, didUnhighlightRowAt indexPath: IndexPath) {
        if let cell = tableView.cellForRow(at: indexPath) { InteractionMotion.setRow(cell, highlighted: false) }
    }

    @objc private func editTapped() { setQueueEditing(!tableView.isEditing) }
    @objc private func clearTapped() { onClearQueue?() }
    @objc private func shuffleTapped() { onShuffleQueue?() }
    @objc private func currentTrackLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began,
              recognizer.location(in: recognizer.view).y > 46,
              tracks.indices.contains(currentIndex) else { return }
        onTrackNavigationRequested?(tracks[currentIndex])
    }
    @objc private func swipedDown() {
        let topOffset = -tableView.adjustedContentInset.top
        guard tableView.contentOffset.y <= topOffset + 1 else { return }
        onDismissSwipe?()
    }
}

private final class QueueTrackCell: SongSwipeActionCell {
    static let reuseIdentifier = "QueueTrackCell"
    private let artwork = UIImageView()
    private lazy var artworkLoader = QueueArtworkLoader(imageView: artwork)
    private let title = UILabel()
    private let metadata = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = DesignSystem.pageBackground
        contentView.backgroundColor = DesignSystem.pageBackground
        selectionStyle = .none
        artwork.translatesAutoresizingMaskIntoConstraints = false
        artwork.contentMode = .scaleAspectFill
        artwork.clipsToBounds = true
        artwork.backgroundColor = DesignSystem.controlFill
        artwork.layer.cornerRadius = DesignSystem.albumArtworkCornerRadius
        title.font = DesignSystem.font(17)
        title.textColor = DesignSystem.primaryText
        title.numberOfLines = 1
        metadata.font = DesignSystem.font(14)
        metadata.textColor = DesignSystem.secondaryText
        metadata.numberOfLines = 1
        let labels = UIStackView(arrangedSubviews: [title, metadata])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.axis = .vertical
        labels.spacing = 4
        contentView.addSubview(artwork)
        contentView.addSubview(labels)
        NSLayoutConstraint.activate([
            artwork.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            artwork.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            artwork.widthAnchor.constraint(equalToConstant: 60),
            artwork.heightAnchor.constraint(equalToConstant: 60),
            labels.leadingAnchor.constraint(equalTo: artwork.trailingAnchor, constant: 16),
            labels.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        artworkLoader.configure(nil)
    }

    func configure(_ track: ScreenTrack) {
        artworkLoader.configure(track)
        title.text = track.title
        metadata.text = "\(track.artist) · \(track.duration.screenTime)"
    }

    func loadArtwork() { artworkLoader.load(pointSize: 60) }
    func cancelArtwork() { artworkLoader.cancel() }
}

/// A request belongs to a displayed image view, never to the whole queue. The
/// pipeline owns the bounded decoded cache; loaders retain only request identity.
private final class QueueArtworkLoader {
    private weak var imageView: UIImageView?
    private var trackID: String?
    private var url: URL?
    private var requestedKey: String?
    private var generation = UUID()

    init(imageView: UIImageView) {
        self.imageView = imageView
    }

    func configure(_ track: ScreenTrack?) {
        if trackID != track?.id || url != track?.artworkURL {
            cancel()
            imageView?.image = track?.artworkURL == nil ? track?.artwork : nil
        } else if track?.artworkURL == nil {
            imageView?.image = track?.artwork
        }
        trackID = track?.id
        url = track?.artworkURL
    }

    func cancel() {
        generation = UUID()
        requestedKey = nil
        if url != nil { imageView?.image = nil }
    }

    func load(pointSize: CGFloat) {
        guard let imageView = imageView, let url = url else { return }
        let scale = imageView.window?.screen.scale ?? UIScreen.main.scale
        let pixelSize = max(1, Int(ceil(pointSize * scale)))
        let key = "remote|\(url.absoluteString)|\(pixelSize)"
        guard requestedKey != key else { return }
        requestedKey = key
        generation = UUID()
        if let image = ArtworkImagePipeline.shared.cachedImage(for: key) {
            imageView.image = image
            return
        }
        let generation = self.generation
        let trackID = self.trackID
        ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: pixelSize) { [weak self] image in
            // Pipeline callbacks are main-queue. ID, URL and generation checks
            // reject reuse, reorder and same-ID/new-cover stale completions.
            guard let self = self, let image = image,
                  self.generation == generation, self.requestedKey == key,
                  self.trackID == trackID, self.url == url else { return }
            self.imageView?.image = image
        }
    }
}

private final class QueuePlayingIndicator: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.clear(rect)
        context.setShouldAntialias(true)
        let heights: [CGFloat] = [0.48, 0.82, 1.0, 0.7]
        let barWidth: CGFloat = 2
        let gap: CGFloat = 2.5
        context.setFillColor(DesignSystem.accent.cgColor)
        for (index, fraction) in heights.enumerated() {
            let height = max(3, rect.height * fraction)
            let x = 0.5 + CGFloat(index) * (barWidth + gap)
            let bar = UIBezierPath(roundedRect: CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height), cornerRadius: 1)
            DesignSystem.accent.setFill()
            bar.fill()
        }
    }
}
