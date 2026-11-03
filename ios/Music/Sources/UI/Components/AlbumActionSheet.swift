import UIKit

/// One row of the album overflow menu (requirement ALB-02). Rows that have no verified
/// backend are shown disabled with a reason instead of pretending to succeed.
struct AlbumAction {
    enum ID: String {
        case library, playlist, playNext, playLater, share, love, dislike, removeDownload
    }

    let id: ID
    let title: String
    let detail: String?
    let glyph: AlbumGlyph
    let isEnabled: Bool
    let isDestructive: Bool
    private let handler: () -> Void

    init(id: ID, title: String, detail: String? = nil, glyph: AlbumGlyph, isEnabled: Bool = true,
         isDestructive: Bool = false, handler: @escaping () -> Void = {}) {
        self.id = id; self.title = title; self.detail = detail; self.glyph = glyph
        self.isEnabled = isEnabled; self.isDestructive = isDestructive; self.handler = handler
    }

    func perform() {
        guard isEnabled else { return }
        handler()
    }
}

/// Small template glyphs drawn in code: iOS 12 has no SF Symbols.
enum AlbumGlyph {
    case play, more, check, download, downloaded, warning, cross, star
    case trash, plus, playlistAdd, playNext, playLater, share, heart, heartSlash

    func image(size: CGFloat = 20) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: size, height: size), format: format).image { context in
            UIColor.black.setFill()
            UIColor.black.setStroke()
            draw(size: size, context: context.cgContext)
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private func draw(size s: CGFloat, context: CGContext) {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        func stroke(_ width: CGFloat = 0.09, _ build: (UIBezierPath) -> Void) {
            let path = UIBezierPath()
            path.lineWidth = width * s
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            build(path)
            path.stroke()
        }
        func lines(_ rows: [(CGFloat, CGFloat, CGFloat)]) {
            stroke { path in for (y, from, to) in rows { path.move(to: p(from, y)); path.addLine(to: p(to, y)) } }
        }
        func triangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) {
            let path = UIBezierPath(); path.move(to: a); path.addLine(to: b); path.addLine(to: c); path.close(); path.fill()
        }
        func heartPath() -> UIBezierPath {
            let path = UIBezierPath()
            path.move(to: p(0.5, 0.86))
            path.addCurve(to: p(0.07, 0.37), controlPoint1: p(0.22, 0.66), controlPoint2: p(0.07, 0.52))
            path.addCurve(to: p(0.5, 0.24), controlPoint1: p(0.07, 0.12), controlPoint2: p(0.4, 0.08))
            path.addCurve(to: p(0.93, 0.37), controlPoint1: p(0.6, 0.08), controlPoint2: p(0.93, 0.12))
            path.addCurve(to: p(0.5, 0.86), controlPoint1: p(0.93, 0.52), controlPoint2: p(0.78, 0.66))
            path.close()
            return path
        }

        switch self {
        case .play:
            triangle(p(0.24, 0.12), p(0.24, 0.88), p(0.88, 0.5))
        case .more:
            for x in [0.2, 0.5, 0.8] as [CGFloat] {
                UIBezierPath(ovalIn: CGRect(x: (x - 0.09) * s, y: 0.41 * s, width: 0.18 * s, height: 0.18 * s)).fill()
            }
        case .check:
            stroke(0.12) { $0.move(to: p(0.16, 0.53)); $0.addLine(to: p(0.41, 0.77)); $0.addLine(to: p(0.85, 0.27)) }
        case .download:
            stroke(0.08) { $0.append(UIBezierPath(ovalIn: CGRect(x: 0.08 * s, y: 0.08 * s, width: 0.84 * s, height: 0.84 * s))) }
            stroke(0.09) {
                $0.move(to: p(0.5, 0.28)); $0.addLine(to: p(0.5, 0.7))
                $0.move(to: p(0.33, 0.53)); $0.addLine(to: p(0.5, 0.7)); $0.addLine(to: p(0.67, 0.53))
            }
        case .downloaded:
            UIBezierPath(ovalIn: CGRect(x: 0.04 * s, y: 0.04 * s, width: 0.92 * s, height: 0.92 * s)).fill()
            context.setBlendMode(.clear)
            stroke(0.1) {
                $0.move(to: p(0.5, 0.26)); $0.addLine(to: p(0.5, 0.7))
                $0.move(to: p(0.32, 0.53)); $0.addLine(to: p(0.5, 0.71)); $0.addLine(to: p(0.68, 0.53))
            }
            context.setBlendMode(.normal)
        case .warning:
            stroke(0.08) { path in
                path.move(to: p(0.5, 0.1)); path.addLine(to: p(0.94, 0.88)); path.addLine(to: p(0.06, 0.88)); path.close()
            }
            stroke(0.1) { $0.move(to: p(0.5, 0.4)); $0.addLine(to: p(0.5, 0.6)) }
            UIBezierPath(ovalIn: CGRect(x: 0.44 * s, y: 0.7 * s, width: 0.12 * s, height: 0.12 * s)).fill()
        case .cross:
            stroke(0.11) { $0.move(to: p(0.22, 0.22)); $0.addLine(to: p(0.78, 0.78)); $0.move(to: p(0.78, 0.22)); $0.addLine(to: p(0.22, 0.78)) }
        case .star:
            let path = UIBezierPath()
            for index in 0..<10 {
                let radius: CGFloat = index % 2 == 0 ? 0.48 : 0.2
                let angle = CGFloat(index) * .pi / 5 - .pi / 2
                let point = p(0.5 + radius * cos(angle), 0.53 + radius * sin(angle))
                index == 0 ? path.move(to: point) : path.addLine(to: point)
            }
            path.close(); path.fill()
        case .trash:
            stroke(0.08) { path in
                path.move(to: p(0.12, 0.24)); path.addLine(to: p(0.88, 0.24))
                path.move(to: p(0.38, 0.24)); path.addLine(to: p(0.4, 0.1)); path.addLine(to: p(0.6, 0.1)); path.addLine(to: p(0.62, 0.24))
                path.move(to: p(0.22, 0.24)); path.addLine(to: p(0.27, 0.9)); path.addLine(to: p(0.73, 0.9)); path.addLine(to: p(0.78, 0.24))
                path.move(to: p(0.42, 0.38)); path.addLine(to: p(0.42, 0.76))
                path.move(to: p(0.58, 0.38)); path.addLine(to: p(0.58, 0.76))
            }
        case .plus:
            stroke(0.1) { $0.move(to: p(0.5, 0.15)); $0.addLine(to: p(0.5, 0.85)); $0.move(to: p(0.15, 0.5)); $0.addLine(to: p(0.85, 0.5)) }
        case .playlistAdd:
            lines([(0.22, 0.08, 0.7), (0.46, 0.08, 0.7), (0.7, 0.08, 0.42)])
            stroke(0.09) { $0.move(to: p(0.74, 0.56)); $0.addLine(to: p(0.74, 0.94)); $0.move(to: p(0.55, 0.75)); $0.addLine(to: p(0.93, 0.75)) }
        case .playNext:
            triangle(p(0.06, 0.1), p(0.06, 0.4), p(0.32, 0.25))
            lines([(0.25, 0.46, 0.94), (0.52, 0.06, 0.94), (0.79, 0.06, 0.94)])
        case .playLater:
            lines([(0.21, 0.06, 0.94), (0.48, 0.06, 0.94), (0.75, 0.46, 0.94)])
            triangle(p(0.06, 0.6), p(0.06, 0.9), p(0.32, 0.75))
        case .share:
            stroke(0.08) { path in
                path.move(to: p(0.33, 0.4)); path.addLine(to: p(0.18, 0.4)); path.addLine(to: p(0.18, 0.92))
                path.addLine(to: p(0.82, 0.92)); path.addLine(to: p(0.82, 0.4)); path.addLine(to: p(0.67, 0.4))
                path.move(to: p(0.5, 0.06)); path.addLine(to: p(0.5, 0.62))
                path.move(to: p(0.33, 0.22)); path.addLine(to: p(0.5, 0.06)); path.addLine(to: p(0.67, 0.22))
            }
        case .heart:
            heartPath().fill()
        case .heartSlash:
            let heart = heartPath(); heart.lineWidth = 0.08 * s; heart.stroke()
            stroke(0.09) { $0.move(to: p(0.1, 0.1)); $0.addLine(to: p(0.9, 0.9)) }
        }
    }
}

/// Reference-B style album menu: dimmed backdrop, rounded card with an album preview
/// header, full-width action rows, Love/Dislike sharing the last row, and a separate Cancel card.
final class AlbumActionSheetController: UIViewController {
    private let album: ScreenAlbum
    private let actions: [AlbumAction]
    private let onPlay: (() -> Void)?
    private let card = UIView()
    private let cancelCard = UIView()

    init(album: ScreenAlbum, actions: [AlbumAction], onPlay: (() -> Void)? = nil) {
        self.album = album
        self.actions = actions
        self.onPlay = onPlay
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }

    static var cardColor: UIColor { ThemeManager.isDark ? UIColor(hex: 0x000000) : UIColor(hex: 0xF7F7F9) }
    static var destructiveColor: UIColor { UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1) }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "albumMenu"
        view.accessibilityViewIsModal = true
        view.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        let backdrop = UIControl()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        view.addSubview(backdrop)

        for surface in [card, cancelCard] {
            surface.translatesAutoresizingMaskIntoConstraints = false
            surface.backgroundColor = Self.cardColor
            surface.layer.cornerRadius = 14
            surface.clipsToBounds = true
            if ThemeManager.isDark {
                // True-black card on a dimmed black page still needs a visible edge.
                surface.layer.borderWidth = 0.5
                surface.layer.borderColor = DesignSystem.separator.cgColor
            }
            view.addSubview(surface)
        }

        let stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        stack.addArrangedSubview(makePreview())
        let paired: Set<AlbumAction.ID> = [.love, .dislike]
        var index = 0
        while index < actions.count {
            stack.addArrangedSubview(separator())
            let action = actions[index]
            if paired.contains(action.id), index + 1 < actions.count, paired.contains(actions[index + 1].id) {
                stack.addArrangedSubview(makePair(action, actions[index + 1]))
                index += 2
            } else {
                stack.addArrangedSubview(makeRow(action))
                index += 1
            }
        }

        let cancelRow = AlbumMenuRow(title: "Cancel", detail: nil, glyph: nil, tint: DesignSystem.accent, centered: true)
        cancelRow.accessibilityIdentifier = "albumMenu.cancel"
        cancelRow.addTarget(self, action: #selector(cancel), for: .touchUpInside)
        cancelCard.addSubview(cancelRow)

        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: view.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            cancelCard.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            cancelCard.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cancelCard.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            cancelCard.heightAnchor.constraint(equalToConstant: 52),
            cancelRow.leadingAnchor.constraint(equalTo: cancelCard.leadingAnchor),
            cancelRow.trailingAnchor.constraint(equalTo: cancelCard.trailingAnchor),
            cancelRow.topAnchor.constraint(equalTo: cancelCard.topAnchor),
            cancelRow.bottomAnchor.constraint(equalTo: cancelCard.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: cancelCard.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: cancelCard.trailingAnchor),
            card.bottomAnchor.constraint(equalTo: cancelCard.topAnchor, constant: -8),
            card.topAnchor.constraint(greaterThanOrEqualTo: guide.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor)
        ])
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    private func run(_ action: AlbumAction) {
        // Act after the sheet is gone so confirmations and the share sheet can present.
        if presentingViewController == nil { action.perform(); return }
        dismiss(animated: true) { action.perform() }
    }

    private func separator() -> UIView {
        let line = UIView()
        line.backgroundColor = DesignSystem.separator
        line.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return line
    }

    private func makeRow(_ action: AlbumAction) -> AlbumMenuRow {
        let tint = action.isDestructive ? Self.destructiveColor : DesignSystem.accent
        let row = AlbumMenuRow(title: action.title, detail: action.detail, glyph: action.glyph, tint: tint, centered: false)
        row.accessibilityIdentifier = "albumMenu.\(action.id.rawValue)"
        row.isEnabled = action.isEnabled
        row.addActionHandler { [weak self] in self?.run(action) }
        return row
    }

    private func makePair(_ left: AlbumAction, _ right: AlbumAction) -> UIView {
        let divider = UIView()
        divider.backgroundColor = DesignSystem.separator
        divider.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
        let leftRow = makeRow(left)
        let rightRow = makeRow(right)
        let pair = UIStackView(arrangedSubviews: [leftRow, divider, rightRow])
        pair.axis = .horizontal
        leftRow.widthAnchor.constraint(equalTo: rightRow.widthAnchor).isActive = true
        return pair
    }

    private func makePreview() -> UIView {
        let preview = UIView()
        preview.accessibilityIdentifier = "albumMenu.preview"
        let art = ArtworkView(image: album.artwork, cornerRadius: DesignSystem.albumArtworkCornerRadius)
        let loader = DetailArtworkLoader(artworkView: art)
        loader.configure(image: album.artwork, url: album.artworkURL)
        loader.load(pointSize: 80)
        objc_setAssociatedObject(preview, &previewLoaderKey, loader, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        let playButton = UIButton(type: .custom)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        playButton.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        playButton.layer.cornerRadius = 15
        playButton.setImage(AlbumGlyph.play.image(size: 12), for: .normal)
        playButton.tintColor = UIColor(hex: 0x3A3A3C)
        playButton.imageEdgeInsets = UIEdgeInsets(top: 0, left: 2, bottom: 0, right: 0)
        playButton.accessibilityLabel = "Play \(album.title)"
        playButton.accessibilityIdentifier = "albumMenu.play"
        playButton.isHidden = onPlay == nil
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)

        let title = ScreenPalette.label(album.title, font: .systemFont(ofSize: 17, weight: .bold), lines: 2)
        let artist = ScreenPalette.label(album.artist, font: .systemFont(ofSize: 15), lines: 1)
        let meta = [album.genre, album.year].filter { !$0.isEmpty }.joined(separator: " • ")
        let info = ScreenPalette.label(meta, font: .systemFont(ofSize: 13), color: ScreenPalette.secondary)
        info.isHidden = meta.isEmpty
        let text = UIStackView(arrangedSubviews: [title, artist, info])
        text.axis = .vertical
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        [art, playButton, text].forEach(preview.addSubview)
        NSLayoutConstraint.activate([
            art.leadingAnchor.constraint(equalTo: preview.leadingAnchor, constant: 16),
            art.topAnchor.constraint(equalTo: preview.topAnchor, constant: 14),
            art.bottomAnchor.constraint(equalTo: preview.bottomAnchor, constant: -14),
            art.widthAnchor.constraint(equalToConstant: 80),
            art.heightAnchor.constraint(equalToConstant: 80),
            playButton.centerXAnchor.constraint(equalTo: art.centerXAnchor),
            playButton.centerYAnchor.constraint(equalTo: art.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 30),
            playButton.heightAnchor.constraint(equalToConstant: 30),
            text.leadingAnchor.constraint(equalTo: art.trailingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: preview.trailingAnchor, constant: -14),
            text.centerYAnchor.constraint(equalTo: art.centerYAnchor)
        ])
        return preview
    }

    @objc private func playTapped() {
        guard let onPlay = onPlay else { return }
        if presentingViewController == nil { onPlay(); return }
        dismiss(animated: true, completion: onPlay)
    }
}

private var previewLoaderKey: UInt8 = 0

/// A full-width menu row: tinted title (with optional reason line) and a trailing glyph.
final class AlbumMenuRow: UIControl {
    private let titleLabel: UILabel
    private let detailLabel: UILabel
    private let icon = UIImageView()
    private let tint: UIColor
    private var handler: (() -> Void)?

    init(title: String, detail: String?, glyph: AlbumGlyph?, tint: UIColor, centered: Bool) {
        self.tint = tint
        titleLabel = ScreenPalette.label(title, font: .systemFont(ofSize: 17), color: tint)
        detailLabel = ScreenPalette.label(detail ?? "", font: .systemFont(ofSize: 12), color: ScreenPalette.secondary)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = [title, detail].compactMap { $0 }.joined(separator: ", ")
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        detailLabel.isHidden = detail == nil
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = glyph?.image(size: 18)
        icon.tintColor = tint
        icon.contentMode = .center
        icon.isHidden = glyph == nil
        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 1
        text.alignment = centered ? .center : .leading
        text.translatesAutoresizingMaskIntoConstraints = false
        text.isUserInteractionEnabled = false
        addSubview(text)
        addSubview(icon)
        let minimumHeight = heightAnchor.constraint(greaterThanOrEqualToConstant: detail == nil ? 46 : 52)
        // Rows keep their natural height; spare space must not stretch the first row.
        let preferredHeight = heightAnchor.constraint(equalToConstant: detail == nil ? 46 : 52)
        preferredHeight.priority = .defaultHigh
        setContentHuggingPriority(.required, for: .vertical)
        NSLayoutConstraint.activate([
            minimumHeight,
            preferredHeight,
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 6),
            icon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22)
        ])
        if centered {
            text.centerXAnchor.constraint(equalTo: centerXAnchor).isActive = true
        } else {
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14).isActive = true
            text.trailingAnchor.constraint(lessThanOrEqualTo: icon.leadingAnchor, constant: -8).isActive = true
        }
        addTarget(self, action: #selector(fire), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func addActionHandler(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc private func fire() { handler?() }

    override var isEnabled: Bool {
        didSet {
            // Disabled rows stay legible; they read as secondary rather than vanishing.
            titleLabel.textColor = isEnabled ? tint : ScreenPalette.secondary
            icon.tintColor = isEnabled ? tint : ScreenPalette.secondary
            accessibilityTraits = isEnabled ? .button : [.button, .notEnabled]
        }
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? DesignSystem.separator.withAlphaComponent(0.6) : .clear }
    }
}
