import UIKit

enum SongSwipeAction: Equatable {
    case enqueue
    case playNext
    case toggleLike
    case more
}

class SongSwipeActionCell: UITableViewCell {
    var onSwipeAction: ((SongSwipeAction) -> Void)?
    var onLongPress: (() -> Void)?

    private let leadingIcon = SongActionIconView()
    private let trailingIcon = SongActionIconView()
    private var activeAction: SongSwipeAction?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureSwipeActions()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSwipeActions()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onSwipeAction = nil
        onLongPress = nil
        activeAction = nil
        contentView.transform = .identity
        leadingIcon.alpha = 0
        trailingIcon.alpha = 0
    }

    private func configureSwipeActions() {
        clipsToBounds = true
        backgroundColor = DesignSystem.pageBackground
        contentView.backgroundColor = DesignSystem.pageBackground
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.minimumPressDuration = 0.45
        addGestureRecognizer(longPress)
        leadingIcon.translatesAutoresizingMaskIntoConstraints = false
        trailingIcon.translatesAutoresizingMaskIntoConstraints = false
        insertSubview(leadingIcon, belowSubview: contentView)
        insertSubview(trailingIcon, belowSubview: contentView)
        NSLayoutConstraint.activate([
            leadingIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 19),
            leadingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingIcon.widthAnchor.constraint(equalToConstant: 30),
            leadingIcon.heightAnchor.constraint(equalToConstant: 30),
            trailingIcon.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -19),
            trailingIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingIcon.widthAnchor.constraint(equalToConstant: 30),
            trailingIcon.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    @objc private func longPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onLongPress?()
    }

    func updateSwipe(translation rawTranslation: CGFloat) {
        let maximum = bounds.width * 0.82
        let translation = max(-maximum, min(maximum, rawTranslation))
        contentView.transform = CGAffineTransform(translationX: translation, y: 0)
        let action = action(for: translation)
        updateBackdrop(translation: translation, action: action)
        activeAction = action
    }

    func finishSwipe(translation rawTranslation: CGFloat) {
        let action = action(for: rawTranslation) ?? activeAction
        reset(animated: true)
        if let action = action { onSwipeAction?(action) }
    }

    func cancelSwipe() {
        reset(animated: true)
    }

    private func action(for translation: CGFloat) -> SongSwipeAction? {
        return SongSwipeActionCell.resolvedAction(for: translation, width: bounds.width)
    }

    static func resolvedAction(for translation: CGFloat, width: CGFloat) -> SongSwipeAction? {
        let distance = abs(translation)
        guard distance >= width * 0.25 else { return nil }
        let isFullSwipe = distance >= width * 0.68
        if translation < 0 { return isFullSwipe ? .playNext : .enqueue }
        return isFullSwipe ? .more : .toggleLike
    }

    private func updateBackdrop(translation: CGFloat, action: SongSwipeAction?) {
        let intensity = min(1, abs(translation) / max(1, bounds.width * 0.45))
        leadingIcon.alpha = translation > 0 ? intensity : 0
        trailingIcon.alpha = translation < 0 ? intensity : 0
        leadingIcon.action = action
        trailingIcon.action = action
        backgroundColor = action?.backgroundColor ?? DesignSystem.pageBackground
        contentView.backgroundColor = DesignSystem.pageBackground
    }

    private func reset(animated: Bool) {
        activeAction = nil
        let changes = {
            self.contentView.transform = .identity
            self.leadingIcon.alpha = 0
            self.trailingIcon.alpha = 0
        }
        let completion: (Bool) -> Void = { _ in self.backgroundColor = DesignSystem.pageBackground }
        if animated {
            UIView.animate(
                withDuration: InteractionMotion.quick,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
                animations: changes,
                completion: completion
            )
        } else {
            changes()
            completion(true)
        }
    }
}

final class SongListSwipeCoordinator: NSObject, UIGestureRecognizerDelegate {
    private weak var tableView: UITableView?
    private weak var activeCell: SongSwipeActionCell?
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))

    init(tableView: UITableView) {
        self.tableView = tableView
        super.init()
        pan.delegate = self
        pan.cancelsTouchesInView = true
        tableView.addGestureRecognizer(pan)
        tableView.panGestureRecognizer.require(toFail: pan)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let tableView = tableView else { return false }
        let velocity = pan.velocity(in: tableView)
        if velocity == .zero { return true }
        return abs(velocity.x) > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = touch.window else { return false }
        let location = touch.location(in: window)
        return location.x > 24 && location.x < window.bounds.width - 24
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        return otherGestureRecognizer === tableView?.panGestureRecognizer
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let tableView = tableView else { return }
        let translation = gesture.translation(in: tableView).x
        switch gesture.state {
        case .began:
            let location = gesture.location(in: tableView)
            guard let indexPath = tableView.indexPathForRow(at: location),
                  let cell = tableView.cellForRow(at: indexPath) as? SongSwipeActionCell else { return }
            activeCell = cell
            cell.updateSwipe(translation: translation)
        case .changed:
            activeCell?.updateSwipe(translation: translation)
        case .ended:
            activeCell?.finishSwipe(translation: translation)
            activeCell = nil
        case .cancelled, .failed:
            activeCell?.cancelSwipe()
            activeCell = nil
        default:
            break
        }
    }
}

final class SongActionIconView: UIView {
    var action: SongSwipeAction? { didSet { setNeedsDisplay() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = false
        isUserInteractionEnabled = false
    }

    override func draw(_ rect: CGRect) {
        guard let action = action, let context = UIGraphicsGetCurrentContext() else { return }
        context.setStrokeColor(UIColor.white.cgColor)
        context.setFillColor(UIColor.white.cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch action {
        case .enqueue:
            for y in [9.0, 15.0, 21.0] {
                context.move(to: CGPoint(x: 5, y: y))
                context.addLine(to: CGPoint(x: 18, y: y))
            }
            context.move(to: CGPoint(x: 23, y: 12))
            context.addLine(to: CGPoint(x: 23, y: 22))
            context.move(to: CGPoint(x: 18, y: 17))
            context.addLine(to: CGPoint(x: 28, y: 17))
            context.strokePath()
        case .playNext:
            context.move(to: CGPoint(x: 6, y: 8))
            context.addLine(to: CGPoint(x: 19, y: 15))
            context.addLine(to: CGPoint(x: 6, y: 22))
            context.closePath()
            context.fillPath()
            context.move(to: CGPoint(x: 23, y: 7))
            context.addLine(to: CGPoint(x: 23, y: 23))
            context.strokePath()
        case .toggleLike:
            let heart = UIBezierPath()
            heart.move(to: CGPoint(x: 15, y: 25))
            heart.addCurve(to: CGPoint(x: 4, y: 12), controlPoint1: CGPoint(x: 10, y: 21), controlPoint2: CGPoint(x: 4, y: 17))
            heart.addCurve(to: CGPoint(x: 15, y: 8), controlPoint1: CGPoint(x: 4, y: 5), controlPoint2: CGPoint(x: 12, y: 5))
            heart.addCurve(to: CGPoint(x: 26, y: 12), controlPoint1: CGPoint(x: 18, y: 5), controlPoint2: CGPoint(x: 26, y: 5))
            heart.addCurve(to: CGPoint(x: 15, y: 25), controlPoint1: CGPoint(x: 26, y: 17), controlPoint2: CGPoint(x: 20, y: 21))
            heart.close()
            heart.fill()
        case .more:
            for x in [7.0, 15.0, 23.0] {
                context.fillEllipse(in: CGRect(x: x - 2, y: 13, width: 4, height: 4))
            }
        }
    }
}

private extension SongSwipeAction {
    var backgroundColor: UIColor {
        switch self {
        case .enqueue, .playNext:
            return DesignSystem.accent
        case .toggleLike:
            return UIColor(red: 1, green: 0.30, blue: 0.39, alpha: 1)
        case .more:
            return UIColor(white: 0.48, alpha: 1)
        }
    }
}
