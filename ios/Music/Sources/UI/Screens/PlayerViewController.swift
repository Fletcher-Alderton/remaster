import UIKit

final class PlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    static func likeConfirmationLabel(isLiked: Bool) -> String {
        return isLiked ? "Added to Likes" : "Removed from Likes"
    }

    var onTogglePlayback: (() -> Void)?
    var onLike: (() -> Bool)?
    var onSeek: ((CGFloat) -> Void)?
    var onOpenQueue: (() -> Void)?
    var onDismissSwipe: (() -> Void)?
    var onSkip: (() -> Void)?
    var onRewind: (() -> Void)?
    var onTrackNavigationRequested: ((ScreenTrack) -> Void)?

    private let artworkContainer = UIView()
    private let artworkShadowCanvas = ArtworkShadowCanvasView()
    private let artworkShadowView = UIView()
    private let artworkView = UIImageView()
    private let bodyView = UIView()
    private let titleLabel = UILabel()
    private let metadataLabel = UILabel()
    private let qualityLabel = UILabel()
    private let waveform = WaveformView()
    private let elapsedLabel = UILabel()
    private let durationLabel = UILabel()
    private let queueButton = UIButton(type: .system)
    private let likeBurst = LikeConfirmationView()
    private var artworkTop: NSLayoutConstraint!
    private var artworkLeading: NSLayoutConstraint!
    private var artworkTrailing: NSLayoutConstraint!
    private var state: PlayerScreenState
    private var acceptsTapGestures = false
    private var hasAppliedArtworkState = false
    private let reduceMotionEnabled: () -> Bool
    private var occurrenceID: String?
    private var gestureDirection: SongChangeDirection?
    // Core Animation stores CATransition under its reserved transition key.
    private static let songChangeAnimationKey = "transition"

    enum SongChangeDirection {
        case next, previous
    }

    // An occurrence identifies a queue entry, not its metadata or downloaded artwork.
    init(state: PlayerScreenState, occurrenceID: String? = nil,
         reduceMotionEnabled: @escaping () -> Bool = { UIAccessibility.isReduceMotionEnabled }) {
        self.state = state
        self.occurrenceID = occurrenceID
        self.reduceMotionEnabled = reduceMotionEnabled
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
        buildView()
        configureGestures()
        update(state: state, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NSLog("NPDIAG player.viewDidAppear title=%@ state=%@", titleLabel.text ?? "nil", state.track.title)
        acceptsTapGestures = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self] in
            guard let self = self,
                  self.viewIfLoaded?.window != nil,
                  self.presentedViewController == nil else { return }
            self.acceptsTapGestures = true
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        acceptsTapGestures = false
    }

    func showPlaybackStatus(_ message: String) {
        guard isViewLoaded else { return }
        qualityLabel.text = message
        qualityLabel.textColor = DesignSystem.secondaryText
        qualityLabel.numberOfLines = 2
    }

    func update(state: PlayerScreenState, occurrenceID: String? = nil,
                direction: SongChangeDirection? = nil, animated: Bool = true) {
        let playbackStateChanged = self.state.isPlaying != state.isPlaying
        let occurrenceChanged = occurrenceID != nil && self.occurrenceID != nil && occurrenceID != self.occurrenceID
        let songChanged = self.state.track.id != state.track.id || occurrenceChanged
        self.state = state
        if let occurrenceID = occurrenceID { self.occurrenceID = occurrenceID }
        if songChanged {
            NSLog("NPDIAG player.update songChanged new=%@ title=%@ loaded=%@ window=%@ shown=%@", state.track.id, state.track.title,
                  isViewLoaded ? "yes" : "no", viewIfLoaded?.window == nil ? "nil" : "yes", titleLabel.text ?? "nil")
        }
        guard isViewLoaded else { return }
        if songChanged {
            // Same-key replacement prevents overlapping transitions on rapid skips.
            // Only the content layers participate: playback sizing, shadows, waveform,
            // and controls keep their independent animation and interaction state.
            let shouldTransition = animated && view.window.map { !$0.isHidden } == true
            transitionSongContent(direction: direction ?? gestureDirection, animated: shouldTransition)
        }
        qualityLabel.textColor = DesignSystem.secondaryText
        qualityLabel.numberOfLines = 1
        artworkView.image = state.track.artwork
        titleLabel.text = state.track.title
        metadataLabel.text = "\(state.track.artist) — \(state.track.album)"
        qualityLabel.text = state.track.quality.isEmpty ? "Qobuz" : state.track.quality
        elapsedLabel.text = state.elapsed.screenTime
        durationLabel.text = state.duration.screenTime
        let progress = state.duration > 0 ? CGFloat(state.elapsed / state.duration) : 0
        waveform.progress = max(0, min(1, progress))
        let remaining = max(0, state.queueCount)
        queueButton.setTitle(remaining == 0 ? "☰   Queue is empty" : "☰   \(remaining) up next", for: .normal)
        if !hasAppliedArtworkState || playbackStateChanged {
            applyArtworkState(isPlaying: state.isPlaying, animated: animated && hasAppliedArtworkState)
            hasAppliedArtworkState = true
        }
        if songChanged {
            NSLog("NPDIAG player.update applied title=%@ alpha=%.2f hidden=%@ anims=%@", titleLabel.text ?? "nil", titleLabel.alpha,
                  titleLabel.isHidden ? "yes" : "no", (titleLabel.layer.animationKeys() ?? []).joined(separator: ","))
        }
    }

    private func transitionSongContent(direction: SongChangeDirection?, animated: Bool) {
        let layers = [artworkView.layer, titleLabel.layer, metadataLabel.layer, qualityLabel.layer]
        let reduceMotion = reduceMotionEnabled()
        for layer in layers {
            layer.removeAnimation(forKey: Self.songChangeAnimationKey)
            guard animated else { continue }
            let transition = CATransition()
            transition.duration = reduceMotion ? 0.18 : 0.24
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            transition.type = .fade
            if !reduceMotion, let direction = direction {
                transition.type = .push
                transition.subtype = direction == .next ? .fromRight : .fromLeft
            }
            transition.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil)
            layer.add(transition, forKey: Self.songChangeAnimationKey)
        }
    }

    private func buildView() {
        view.accessibilityIdentifier = "player"
        view.isAccessibilityElement = false
        view.accessibilityLabel = "Now Playing"
        view.backgroundColor = DesignSystem.pageBackground

        artworkContainer.translatesAutoresizingMaskIntoConstraints = false
        artworkContainer.backgroundColor = .clear
        artworkContainer.clipsToBounds = false
        view.addSubview(artworkContainer)

        artworkShadowCanvas.translatesAutoresizingMaskIntoConstraints = false
        artworkShadowCanvas.alpha = 0
        artworkContainer.addSubview(artworkShadowCanvas)

        artworkShadowView.translatesAutoresizingMaskIntoConstraints = false
        artworkShadowView.accessibilityIdentifier = "player.artwork"
        artworkShadowView.isAccessibilityElement = true
        artworkShadowView.accessibilityLabel = "Album artwork"
        artworkShadowView.backgroundColor = DesignSystem.pageBackground
        artworkShadowView.clipsToBounds = false
        artworkContainer.addSubview(artworkShadowView)

        artworkView.translatesAutoresizingMaskIntoConstraints = false
        artworkView.contentMode = .scaleAspectFill
        artworkView.clipsToBounds = true
        artworkView.backgroundColor = DesignSystem.controlFill
        artworkShadowView.addSubview(artworkView)
        artworkView.pinEdges(to: artworkShadowView)

        artworkTop = artworkShadowView.topAnchor.constraint(equalTo: artworkContainer.topAnchor)
        artworkLeading = artworkShadowView.leadingAnchor.constraint(equalTo: artworkContainer.leadingAnchor)
        artworkTrailing = artworkShadowView.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor)

        bodyView.translatesAutoresizingMaskIntoConstraints = false
        bodyView.backgroundColor = DesignSystem.pageBackground
        view.addSubview(bodyView)

        configure(label: titleLabel, size: 18, weight: .bold, color: DesignSystem.primaryText)
        titleLabel.accessibilityIdentifier = "player.title"
        configure(label: metadataLabel, size: 13, weight: .regular, color: DesignSystem.secondaryText)
        metadataLabel.accessibilityIdentifier = "player.metadata"
        configure(label: qualityLabel, size: 10, weight: .regular, color: DesignSystem.secondaryText)
        qualityLabel.accessibilityIdentifier = "player.quality"
        configure(label: elapsedLabel, size: 9, weight: .regular, color: DesignSystem.secondaryText)
        configure(label: durationLabel, size: 9, weight: .regular, color: DesignSystem.secondaryText)

        waveform.translatesAutoresizingMaskIntoConstraints = false
        waveform.accessibilityIdentifier = "player.waveform"
        waveform.isAccessibilityElement = true
        waveform.accessibilityLabel = "Playback waveform"
        waveform.onSeek = { [weak self] ratio in self?.onSeek?(ratio) }

        queueButton.translatesAutoresizingMaskIntoConstraints = false
        queueButton.contentHorizontalAlignment = .left
        queueButton.setTitleColor(DesignSystem.secondaryText, for: .normal)
        queueButton.titleLabel?.font = DesignSystem.font(11)
        queueButton.addTarget(self, action: #selector(openQueue), for: .touchUpInside)

        [titleLabel, metadataLabel, qualityLabel, waveform, elapsedLabel, durationLabel, queueButton].forEach(bodyView.addSubview)

        likeBurst.translatesAutoresizingMaskIntoConstraints = false
        likeBurst.alpha = 0
        likeBurst.isAccessibilityElement = true
        likeBurst.accessibilityIdentifier = "player.likeConfirmation"
        likeBurst.accessibilityElementsHidden = true
        likeBurst.layer.shadowColor = UIColor.black.cgColor
        likeBurst.layer.shadowOpacity = 0.35
        likeBurst.layer.shadowRadius = 12
        view.addSubview(likeBurst)

        NSLayoutConstraint.activate([
            artworkContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            artworkContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            artworkContainer.topAnchor.constraint(equalTo: view.topAnchor),
            artworkContainer.heightAnchor.constraint(equalTo: artworkContainer.widthAnchor),
            artworkTop, artworkLeading, artworkTrailing,
            artworkShadowView.heightAnchor.constraint(equalTo: artworkShadowView.widthAnchor),
            artworkShadowCanvas.leadingAnchor.constraint(equalTo: artworkShadowView.leadingAnchor, constant: -24),
            artworkShadowCanvas.trailingAnchor.constraint(equalTo: artworkShadowView.trailingAnchor, constant: 24),
            artworkShadowCanvas.topAnchor.constraint(equalTo: artworkShadowView.topAnchor, constant: -24),
            artworkShadowCanvas.bottomAnchor.constraint(equalTo: artworkShadowView.bottomAnchor, constant: 24),

            bodyView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bodyView.topAnchor.constraint(equalTo: artworkContainer.bottomAnchor),
            bodyView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 22),
            titleLabel.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor, constant: -22),
            titleLabel.topAnchor.constraint(equalTo: bodyView.topAnchor, constant: 17),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 5),
            qualityLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            qualityLabel.topAnchor.constraint(equalTo: metadataLabel.bottomAnchor, constant: 7),

            waveform.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 22),
            waveform.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor, constant: -22),
            waveform.topAnchor.constraint(equalTo: qualityLabel.bottomAnchor, constant: 22),
            waveform.heightAnchor.constraint(equalToConstant: 54),
            elapsedLabel.leadingAnchor.constraint(equalTo: waveform.leadingAnchor),
            elapsedLabel.topAnchor.constraint(equalTo: waveform.bottomAnchor, constant: 4),
            durationLabel.trailingAnchor.constraint(equalTo: waveform.trailingAnchor),
            durationLabel.topAnchor.constraint(equalTo: waveform.bottomAnchor, constant: 4),

            queueButton.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 22),
            queueButton.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor, constant: -22),
            queueButton.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor, constant: -13),
            queueButton.heightAnchor.constraint(equalToConstant: 34),

            likeBurst.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
            likeBurst.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
            likeBurst.widthAnchor.constraint(equalToConstant: 72),
            likeBurst.heightAnchor.constraint(equalToConstant: 72)
        ])
    }

    private func configureGestures() {
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.45
        longPress.delegate = self
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(singleTapped))
        singleTap.require(toFail: doubleTap)
        singleTap.require(toFail: longPress)
        singleTap.delegate = self
        view.addGestureRecognizer(longPress)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(singleTap)

        let dismissSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedDown))
        dismissSwipe.direction = .down
        view.addGestureRecognizer(dismissSwipe)
        let queueSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedUp))
        queueSwipe.direction = .up
        view.addGestureRecognizer(queueSwipe)
        let skipSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedLeft))
        skipSwipe.direction = .left
        skipSwipe.delegate = self
        view.addGestureRecognizer(skipSwipe)
        let rewindSwipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedRight))
        rewindSwipe.direction = .right
        rewindSwipe.delegate = self
        view.addGestureRecognizer(rewindSwipe)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        return touch.view?.isDescendant(of: waveform) != true && !(touch.view is UIControl)
    }

    private func applyArtworkState(isPlaying: Bool, animated: Bool) {
        view.layoutIfNeeded()
        let shadowAlpha: CGFloat
        if isPlaying {
            artworkTop.constant = 0
            artworkLeading.constant = 0
            artworkTrailing.constant = 0
            artworkView.layer.cornerRadius = 0
            artworkShadowView.layer.cornerRadius = 0
            shadowAlpha = 0
        } else {
            artworkTop.constant = 34
            artworkLeading.constant = 34
            artworkTrailing.constant = -34
            artworkView.layer.cornerRadius = DesignSystem.albumArtworkCornerRadius
            artworkShadowView.layer.cornerRadius = DesignSystem.albumArtworkCornerRadius
            artworkShadowCanvas.setNeedsDisplay()
            shadowAlpha = 1
        }
        let changes = {
            self.view.layoutIfNeeded()
            self.artworkShadowCanvas.alpha = shadowAlpha
        }
        if animated {
            UIView.animate(
                withDuration: InteractionMotion.navigation,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
                animations: changes
            )
        } else {
            changes()
        }
    }

    private func configure(label: UILabel, size: CGFloat, weight: UIFont.Weight, color: UIColor) {
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = DesignSystem.font(size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
    }

    private func showLikeBurst(isLiked: Bool) {
        likeBurst.layer.removeAllAnimations()
        likeBurst.isLiked = isLiked
        likeBurst.accessibilityLabel = PlayerViewController.likeConfirmationLabel(isLiked: isLiked)
        likeBurst.accessibilityElementsHidden = false
        likeBurst.alpha = 0
        likeBurst.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
        UIView.animateKeyframes(withDuration: 0.46, delay: 0, options: [.allowUserInteraction], animations: {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
                self.likeBurst.alpha = 1
                self.likeBurst.transform = CGAffineTransform(scaleX: 1.08, y: 1.08)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.25, relativeDuration: 0.75) {
                self.likeBurst.alpha = 0
                self.likeBurst.transform = CGAffineTransform(scaleX: 1.2, y: 1.2)
            }
        }, completion: { _ in
            self.likeBurst.alpha = 0
            self.likeBurst.accessibilityElementsHidden = true
        })
    }

    @objc private func singleTapped() {
        guard acceptsTapGestures else { return }
        onTogglePlayback?()
    }
    @objc private func doubleTapped() {
        guard acceptsTapGestures else { return }
        guard let isLiked = onLike?() else { return }
        showLikeBurst(isLiked: isLiked)
    }
    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onTrackNavigationRequested?(state.track)
    }
    @objc private func openQueue() { onOpenQueue?() }

    @objc private func swipedDown() { onDismissSwipe?() }
    @objc private func swipedUp() { onOpenQueue?() }
    @objc private func swipedLeft() {
        gestureDirection = .next
        defer { gestureDirection = nil }
        onSkip?()
    }
    @objc private func swipedRight() {
        // Previous may seek to zero instead of changing songs. Scope the hint to
        // this action so a later automatic/queue change cannot inherit it.
        gestureDirection = .previous
        defer { gestureDirection = nil }
        onRewind?()
    }
}

private final class ArtworkShadowCanvasView: UIView {
    private let canvasInset: CGFloat = 24

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let cardRect = bounds.insetBy(dx: canvasInset, dy: canvasInset)
        guard cardRect.width > 0, cardRect.height > 0 else { return }

        let card = UIBezierPath(
            roundedRect: cardRect,
            cornerRadius: DesignSystem.albumArtworkCornerRadius
        )

        let ambientColor = ThemeManager.isDark
            ? UIColor.white.withAlphaComponent(0.16)
            : UIColor.black.withAlphaComponent(0.32)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 4),
            blur: 14,
            color: ambientColor.cgColor
        )
        context.setFillColor(DesignSystem.pageBackground.cgColor)
        context.addPath(card.cgPath)
        context.fillPath()
        context.restoreGState()

        let contactColor = ThemeManager.isDark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.26)
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 2),
            blur: 5,
            color: contactColor.cgColor
        )
        context.setFillColor(DesignSystem.pageBackground.cgColor)
        context.addPath(card.cgPath)
        context.fillPath()
        context.restoreGState()
    }
}

private final class LikeConfirmationView: UIView {
    var isLiked = true {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.35
        layer.shadowRadius = 12
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        let scale = min(rect.width, rect.height) / 72
        let context = UIGraphicsGetCurrentContext()
        context?.saveGState()
        context?.translateBy(x: (rect.width - 72 * scale) / 2, y: (rect.height - 72 * scale) / 2)
        context?.scaleBy(x: scale, y: scale)

        let heart = UIBezierPath()
        heart.move(to: CGPoint(x: 36, y: 63))
        heart.addCurve(
            to: CGPoint(x: 8, y: 31),
            controlPoint1: CGPoint(x: 29, y: 56),
            controlPoint2: CGPoint(x: 8, y: 43)
        )
        heart.addCurve(
            to: CGPoint(x: 23, y: 11),
            controlPoint1: CGPoint(x: 8, y: 19),
            controlPoint2: CGPoint(x: 17, y: 11)
        )
        heart.addCurve(
            to: CGPoint(x: 36, y: 20),
            controlPoint1: CGPoint(x: 30, y: 11),
            controlPoint2: CGPoint(x: 34, y: 16)
        )
        heart.addCurve(
            to: CGPoint(x: 49, y: 11),
            controlPoint1: CGPoint(x: 38, y: 16),
            controlPoint2: CGPoint(x: 42, y: 11)
        )
        heart.addCurve(
            to: CGPoint(x: 64, y: 31),
            controlPoint1: CGPoint(x: 55, y: 11),
            controlPoint2: CGPoint(x: 64, y: 19)
        )
        heart.addCurve(
            to: CGPoint(x: 36, y: 63),
            controlPoint1: CGPoint(x: 64, y: 43),
            controlPoint2: CGPoint(x: 43, y: 56)
        )
        heart.close()
        UIColor.white.setFill()
        heart.fill()

        if !isLiked {
            let crack = UIBezierPath()
            crack.move(to: CGPoint(x: 39, y: 16))
            crack.addLine(to: CGPoint(x: 31, y: 31))
            crack.addLine(to: CGPoint(x: 40, y: 38))
            crack.addLine(to: CGPoint(x: 32, y: 54))
            crack.lineWidth = 4
            crack.lineCapStyle = .butt
            crack.lineJoinStyle = .miter
            DesignSystem.pageBackground.setStroke()
            crack.stroke()
        }

        context?.restoreGState()
    }
}
