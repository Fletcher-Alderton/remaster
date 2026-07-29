import UIKit

final class MiniPlayerView: UIControl {
    var onTogglePlayback: (() -> Void)?
    var onOpenPlayer: (() -> Void)?

    let artworkImageView = UIImageView()
    let titleLabel = UILabel()
    let artistLabel = UILabel()
    let playPauseButton = UIButton(type: .custom)

    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .light))
    private let progressView = UIView()
    private let openButton = UIButton(type: .custom)
    private var progressWidthConstraint: NSLayoutConstraint?
    private var isPlaying = false
    private var playbackProgress: CGFloat = 0

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func configure(title: String, artist: String, artwork: UIImage?, isPlaying: Bool, progress: CGFloat) {
        titleLabel.text = title
        artistLabel.text = artist
        openButton.accessibilityLabel = "\(title), \(artist)"
        openButton.accessibilityValue = isPlaying ? "Playing" : "Paused"
        artworkImageView.image = artwork
        setPlaying(isPlaying)
        setProgress(progress, animated: false)
    }

    func setPlaying(_ playing: Bool) {
        isPlaying = playing
        let image = playerSymbol(isPlaying: playing)
        playPauseButton.setImage(image, for: .normal)
        playPauseButton.accessibilityLabel = playing ? "Pause" : "Play"
        openButton.accessibilityValue = playing ? "Playing" : "Paused"
    }

    func setProgress(_ progress: CGFloat, animated: Bool = true) {
        layoutIfNeeded()
        playbackProgress = min(max(progress, 0), 1)
        progressWidthConstraint?.constant = bounds.width * playbackProgress
        let changes = { self.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.18, animations: changes)
        } else {
            changes()
        }
    }

    func applyTheme() {
        blurView.effect = UIBlurEffect(style: ThemeManager.isDark ? .dark : .light)
        layer.borderColor = DesignSystem.separator.withAlphaComponent(0.9).cgColor
        progressView.backgroundColor = DesignSystem.accentMuted
        artworkImageView.backgroundColor = DesignSystem.groupedBackground
        titleLabel.textColor = DesignSystem.primaryText
        artistLabel.textColor = DesignSystem.secondaryText
        playPauseButton.tintColor = DesignSystem.primaryText
        setPlaying(isPlaying)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let progressWidth = progressWidthConstraint, bounds.width > 0 {
            progressWidth.constant = bounds.width * playbackProgress
        }
    }

    private func configureView() {
        accessibilityIdentifier = "miniPlayer"
        isAccessibilityElement = false
        backgroundColor = .clear
        layer.cornerRadius = 10
        layer.borderWidth = 0.5
        layer.borderColor = DesignSystem.separator.withAlphaComponent(0.9).cgColor
        clipsToBounds = true

        blurView.effect = UIBlurEffect(style: ThemeManager.isDark ? .dark : .light)
        blurView.isUserInteractionEnabled = false
        blurView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blurView)
        blurView.pinEdges(to: self)

        progressView.backgroundColor = DesignSystem.accentMuted
        progressView.isUserInteractionEnabled = false
        progressView.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(progressView, aboveSubview: blurView)
        progressWidthConstraint = progressView.widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            progressView.leadingAnchor.constraint(equalTo: leadingAnchor),
            progressView.topAnchor.constraint(equalTo: topAnchor),
            progressView.bottomAnchor.constraint(equalTo: bottomAnchor),
            progressWidthConstraint!
        ])

        artworkImageView.contentMode = .scaleAspectFill
        artworkImageView.clipsToBounds = true
        artworkImageView.layer.cornerRadius = DesignSystem.albumArtworkCornerRadius
        artworkImageView.backgroundColor = DesignSystem.groupedBackground
        artworkImageView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = DesignSystem.font(12, weight: .semibold)
        titleLabel.textColor = DesignSystem.primaryText
        titleLabel.numberOfLines = 1
        titleLabel.isAccessibilityElement = false
        artistLabel.font = DesignSystem.font(10)
        artistLabel.textColor = DesignSystem.secondaryText
        artistLabel.numberOfLines = 1
        artistLabel.isAccessibilityElement = false
        let labelStack = UIStackView(arrangedSubviews: [titleLabel, artistLabel])
        labelStack.axis = .vertical
        labelStack.spacing = 1
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        playPauseButton.tintColor = DesignSystem.primaryText
        playPauseButton.accessibilityIdentifier = "miniPlayer.playPause"
        playPauseButton.contentHorizontalAlignment = .center
        playPauseButton.contentVerticalAlignment = .center
        playPauseButton.accessibilityTraits = .button
        playPauseButton.addTarget(self, action: #selector(didTapPlayback), for: .touchUpInside)
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(artworkImageView)
        addSubview(labelStack)
        addSubview(playPauseButton)
        openButton.translatesAutoresizingMaskIntoConstraints = false
        openButton.backgroundColor = .clear
        openButton.accessibilityIdentifier = "miniPlayer.open"
        openButton.accessibilityLabel = "Open Now Playing"
        openButton.accessibilityTraits = .button
        openButton.addTarget(self, action: #selector(didTapMiniPlayer), for: .touchUpInside)
        addSubview(openButton)
        bringSubviewToFront(playPauseButton)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: DesignSystem.miniPlayerHeight),
            artworkImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            artworkImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            artworkImageView.widthAnchor.constraint(equalToConstant: 38),
            artworkImageView.heightAnchor.constraint(equalTo: artworkImageView.widthAnchor),
            labelStack.leadingAnchor.constraint(equalTo: artworkImageView.trailingAnchor, constant: 9),
            labelStack.trailingAnchor.constraint(equalTo: playPauseButton.leadingAnchor, constant: -8),
            labelStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            playPauseButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            playPauseButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 37),
            playPauseButton.heightAnchor.constraint(equalToConstant: 37),
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            openButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            openButton.topAnchor.constraint(equalTo: topAnchor),
            openButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        setPlaying(false)
    }

    override func accessibilityActivate() -> Bool {
        onOpenPlayer?()
        return true
    }

    private func playerSymbol(isPlaying: Bool) -> UIImage? {
        return isPlaying ? MiniPlayerSymbol.pause : MiniPlayerSymbol.play
    }

    @objc private func didTapPlayback() {
        onTogglePlayback?()
    }

    @objc private func didTapMiniPlayer() {
        onOpenPlayer?()
    }
}

private enum MiniPlayerSymbol {
    static let play = make(isPlaying: false)
    static let pause = make(isPlaying: true)

    private static func make(isPlaying: Bool) -> UIImage? {
        let size = CGSize(width: 17, height: 17)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        let context = UIGraphicsGetCurrentContext()
        context?.setFillColor(UIColor.black.cgColor)
        if isPlaying {
            context?.fill(CGRect(x: 2, y: 1, width: 4, height: 15))
            context?.fill(CGRect(x: 11, y: 1, width: 4, height: 15))
        } else {
            context?.move(to: CGPoint(x: 3, y: 1))
            context?.addLine(to: CGPoint(x: 16, y: 8.5))
            context?.addLine(to: CGPoint(x: 3, y: 16))
            context?.closePath()
            context?.fillPath()
        }
        return UIGraphicsGetImageFromCurrentImageContext()?.withRenderingMode(.alwaysTemplate)
    }
}
