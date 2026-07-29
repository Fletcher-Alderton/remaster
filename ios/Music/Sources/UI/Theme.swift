import UIKit
import ObjectiveC

enum AppearanceMode: String, CaseIterable {
    case light
    case dark
    case automatic

    var title: String {
        switch self {
        case .light: return "Light"
        case .dark: return "Dark"
        case .automatic: return "Auto"
        }
    }
}

enum ThemeManager {
    static let didChangeNotification = Notification.Name("MusicThemeDidChange")
    private static let defaultsKey = "appearanceMode"
    private static var timer: Timer?
    private(set) static var isDark = resolvedIsDark()

    static var mode: AppearanceMode {
        get {
            guard let value = UserDefaults.standard.string(forKey: defaultsKey),
                  let mode = AppearanceMode(rawValue: value) else { return .automatic }
            return mode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            refresh(force: true)
        }
    }

    static func startAutomaticMonitoring() {
        refresh(force: false)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            refresh(force: false)
        }
    }

    static func refresh(force: Bool = false) {
        let resolved = resolvedIsDark()
        guard force || resolved != isDark else { return }
        isDark = resolved
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }

    static func isNight(hour: Int) -> Bool {
        return hour < 7 || hour >= 19
    }

    private static func resolvedIsDark() -> Bool {
        switch mode {
        case .light: return false
        case .dark: return true
        case .automatic:
            return isNight(hour: Calendar.current.component(.hour, from: Date()))
        }
    }
}

enum DesignSystem {
    static let accent = UIColor(red: 51.0 / 255.0, green: 156.0 / 255.0, blue: 1.0, alpha: 1.0)
    static let accentMuted = UIColor(red: 51.0 / 255.0, green: 156.0 / 255.0, blue: 1.0, alpha: 0.16)
    static var pageBackground: UIColor { return ThemeManager.isDark ? UIColor(hex: 0x000000) : .white }
    static var groupedBackground: UIColor { return ThemeManager.isDark ? UIColor(hex: 0x111114) : UIColor(hex: 0xF7F7F9) }
    static var primaryText: UIColor { return ThemeManager.isDark ? UIColor(hex: 0xF4F4F7) : UIColor(hex: 0x121214) }
    static var secondaryText: UIColor { return ThemeManager.isDark ? UIColor(hex: 0x98989F) : UIColor(hex: 0x74747A) }
    static var separator: UIColor { return ThemeManager.isDark ? UIColor(hex: 0x2A2A2F) : UIColor(hex: 0xE5E5EA) }
    static var controlFill: UIColor { return ThemeManager.isDark ? UIColor(hex: 0x1C1C20) : UIColor(hex: 0xF1F1F5) }
    static var settingsBackground: UIColor { return ThemeManager.isDark ? UIColor(hex: 0x0B0B0E) : UIColor(hex: 0xF4F4F7) }
    static var actionFill: UIColor { return ThemeManager.isDark ? UIColor(hex: 0x13283B) : UIColor(hex: 0xE9F4FF) }

    static let screenWidth: CGFloat = 320
    static let screenHeight: CGFloat = 568
    static let horizontalInset: CGFloat = 12
    static let miniPlayerHeight: CGFloat = 50
    static let cornerRadius: CGFloat = 10
    static let albumArtworkCornerRadius: CGFloat = 4

    static func font(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    static func rounded(_ view: UIView, radius: CGFloat = DesignSystem.cornerRadius) {
        view.layer.cornerRadius = radius
        view.layer.masksToBounds = true
    }

    static func applyCardShadow(to view: UIView, opacity: Float = 0.10, radius: CGFloat = 12, offset: CGSize = CGSize(width: 0, height: 4)) {
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = opacity
        view.layer.shadowRadius = radius
        view.layer.shadowOffset = offset
        view.layer.masksToBounds = false
    }
}

enum ThemeApplier {
    static func apply(to root: UIView) {
        applyColors(to: root)
        // UIVisualEffectView owns private rendering views. Recoloring those
        // internals can break blur compositing on older versions of iOS.
        guard !(root is UIVisualEffectView) else { return }
        root.subviews.forEach(apply)
    }

    private static func applyColors(to view: UIView) {
        if let background = view.backgroundColor {
            if background.matchesAny([.white, .black]) {
                view.backgroundColor = DesignSystem.pageBackground
            } else if background.matchesAny([UIColor(hex: 0xF7F7F9), UIColor(hex: 0x111114), UIColor(hex: 0xF4F4F7), UIColor(hex: 0x0B0B0E)]) {
                view.backgroundColor = DesignSystem.groupedBackground
            } else if background.matchesAny([UIColor(hex: 0xF1F1F5), UIColor(hex: 0x1C1C20), UIColor(white: 0.95, alpha: 1)]) {
                view.backgroundColor = DesignSystem.controlFill
            } else if background.matchesAny([UIColor(hex: 0xE9F4FF), UIColor(hex: 0x13283B)]) {
                view.backgroundColor = DesignSystem.actionFill
            }
        }

        if let label = view as? UILabel {
            if label.textColor.matchesSemanticPrimary {
                label.textColor = DesignSystem.primaryText
            } else if label.textColor.matchesSemanticSecondary {
                label.textColor = DesignSystem.secondaryText
            }
        }
        if let button = view as? UIButton {
            if let titleColor = button.titleColor(for: .normal) {
                if titleColor.matchesSemanticPrimary {
                    button.setTitleColor(DesignSystem.primaryText, for: .normal)
                } else if titleColor.matchesSemanticSecondary {
                    button.setTitleColor(DesignSystem.secondaryText, for: .normal)
                }
            }
            if button.tintColor.matchesSemanticPrimary {
                button.tintColor = DesignSystem.primaryText
            }
        }
        if let textField = view as? UITextField {
            textField.textColor = DesignSystem.primaryText
            textField.keyboardAppearance = ThemeManager.isDark ? .dark : .light
        }
        if let table = view as? UITableView {
            table.separatorColor = DesignSystem.separator
            table.indicatorStyle = ThemeManager.isDark ? .white : .default
        }
        if let scroll = view as? UIScrollView {
            scroll.indicatorStyle = ThemeManager.isDark ? .white : .default
        }
        if let blur = view as? UIVisualEffectView {
            blur.effect = UIBlurEffect(style: ThemeManager.isDark ? .dark : .light)
        }
        if let border = view.layer.borderColor,
           UIColor(cgColor: border).matchesSemanticSeparator {
            view.layer.borderColor = DesignSystem.separator.cgColor
        }
        view.setNeedsDisplay()
    }
}

private var quickMotionInstalledKey: UInt8 = 0

enum InteractionMotion {
    static let quick: TimeInterval = 0.18
    static let navigation: TimeInterval = 0.22

    static func install(in rootView: UIView) {
        if let button = rootView as? UIButton,
           objc_getAssociatedObject(button, &quickMotionInstalledKey) == nil {
            objc_setAssociatedObject(button, &quickMotionInstalledKey, true, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            button.addTarget(QuickMotionTarget.shared, action: #selector(QuickMotionTarget.pressed(_:)), for: .touchDown)
            button.addTarget(
                QuickMotionTarget.shared,
                action: #selector(QuickMotionTarget.released(_:)),
                for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
            )
        }
        rootView.subviews.forEach(install)
    }

    static func setRow(_ view: UIView, highlighted: Bool) {
        UIView.animate(
            withDuration: highlighted ? 0.10 : quick,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: {
                view.alpha = highlighted ? 0.62 : 1
                view.transform = highlighted
                    ? CGAffineTransform(scaleX: 0.992, y: 0.992)
                    : .identity
            }
        )
    }

    static func present(_ controller: UIViewController, from presenter: UIViewController) {
        presenter.present(controller, animated: false) {
            controller.view.layoutIfNeeded()
            install(in: controller.view)
            let animatedStates = controller.view.subviews.map {
                (view: $0, alpha: $0.alpha, transform: $0.transform)
            }
            animatedStates.forEach {
                $0.view.alpha = 0
                $0.view.transform = $0.transform.translatedBy(x: 0, y: 12)
            }
            UIView.animate(
                withDuration: navigation,
                delay: 0,
                options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
                animations: {
                    animatedStates.forEach {
                        $0.view.alpha = $0.alpha
                        $0.view.transform = $0.transform
                    }
                }
            )
        }
    }

    static func dismiss(_ controller: UIViewController, completion: (() -> Void)? = nil) {
        let animatedStates = controller.view.subviews.map {
            (view: $0, alpha: $0.alpha, transform: $0.transform)
        }
        UIView.animate(
            withDuration: quick,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn],
            animations: {
                animatedStates.forEach {
                    $0.view.alpha = 0
                    $0.view.transform = $0.transform.translatedBy(x: 0, y: 10)
                }
            },
            completion: { _ in
                controller.dismiss(animated: false) {
                    animatedStates.forEach {
                        $0.view.alpha = $0.alpha
                        $0.view.transform = $0.transform
                    }
                    completion?()
                }
            }
        )
    }
}

private final class QuickMotionTarget: NSObject {
    static let shared = QuickMotionTarget()

    @objc func pressed(_ control: UIControl) {
        if objc_getAssociatedObject(control, &quickMotionOriginalStateKey) == nil {
            objc_setAssociatedObject(
                control,
                &quickMotionOriginalStateKey,
                QuickMotionState(alpha: control.alpha, transform: control.transform),
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
        guard let state = objc_getAssociatedObject(control, &quickMotionOriginalStateKey) as? QuickMotionState else {
            return
        }
        UIView.animate(
            withDuration: 0.09,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: {
                control.transform = state.transform.scaledBy(x: 0.96, y: 0.96)
                control.alpha = state.alpha * 0.72
            }
        )
    }

    @objc func released(_ control: UIControl) {
        guard let state = objc_getAssociatedObject(control, &quickMotionOriginalStateKey) as? QuickMotionState else {
            return
        }
        UIView.animate(
            withDuration: InteractionMotion.quick,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: {
                control.transform = state.transform
                control.alpha = state.alpha
            },
            completion: { _ in
                objc_setAssociatedObject(
                    control,
                    &quickMotionOriginalStateKey,
                    nil,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
        )
    }
}

private var quickMotionOriginalStateKey: UInt8 = 0

private final class QuickMotionState: NSObject {
    let alpha: CGFloat
    let transform: CGAffineTransform

    init(alpha: CGFloat, transform: CGAffineTransform) {
        self.alpha = alpha
        self.transform = transform
    }
}

enum MusicSymbol {
    static func shuffle(size: CGSize = CGSize(width: 24, height: 24)) -> UIImage {
        if #available(iOS 13.0, *) {
            let configuration = UIImage.SymbolConfiguration(pointSize: min(size.width, size.height), weight: .semibold)
            if let image = UIImage(systemName: "shuffle", withConfiguration: configuration) {
                return image
            }
        }
        if let fallback = UIImage(named: "ShuffleSymbol") {
            return fallback.withRenderingMode(.alwaysTemplate)
        }
        return draw(size: size) { color in
            color.setStroke()
            color.setFill()

            let upper = UIBezierPath()
            upper.lineWidth = 2.15
            upper.lineCapStyle = .round
            upper.lineJoinStyle = .round
            upper.move(to: CGPoint(x: 2.5, y: 6.5))
            upper.addCurve(
                to: CGPoint(x: 14.2, y: 17.5),
                controlPoint1: CGPoint(x: 7.5, y: 6.5),
                controlPoint2: CGPoint(x: 8.8, y: 17.5)
            )
            upper.addLine(to: CGPoint(x: 18.7, y: 17.5))
            upper.stroke()
            arrowHead(at: CGPoint(x: 21.2, y: 17.5), direction: .right, color: color)

            let lower = UIBezierPath()
            lower.lineWidth = 2.15
            lower.lineCapStyle = .round
            lower.lineJoinStyle = .round
            lower.move(to: CGPoint(x: 2.5, y: 17.5))
            lower.addCurve(
                to: CGPoint(x: 14.2, y: 6.5),
                controlPoint1: CGPoint(x: 7.5, y: 17.5),
                controlPoint2: CGPoint(x: 8.8, y: 6.5)
            )
            lower.addLine(to: CGPoint(x: 18.7, y: 6.5))
            lower.stroke()
            arrowHead(at: CGPoint(x: 21.2, y: 6.5), direction: .right, color: color)
        }
    }

    static func repeatIcon(size: CGSize = CGSize(width: 24, height: 24)) -> UIImage {
        if #available(iOS 13.0, *) {
            let configuration = UIImage.SymbolConfiguration(pointSize: min(size.width, size.height), weight: .semibold)
            if let image = UIImage(systemName: "repeat", withConfiguration: configuration) {
                return image
            }
        }
        if let fallback = UIImage(named: "RepeatSymbol") {
            return fallback.withRenderingMode(.alwaysTemplate)
        }
        return draw(size: size) { color in
            color.setStroke()
            color.setFill()

            let top = UIBezierPath()
            top.lineWidth = 2.15
            top.lineCapStyle = .round
            top.lineJoinStyle = .round
            top.move(to: CGPoint(x: 4.2, y: 9.2))
            top.addCurve(
                to: CGPoint(x: 8, y: 5.6),
                controlPoint1: CGPoint(x: 4.2, y: 7.2),
                controlPoint2: CGPoint(x: 5.9, y: 5.6)
            )
            top.addLine(to: CGPoint(x: 18.6, y: 5.6))
            top.stroke()
            arrowHead(at: CGPoint(x: 21, y: 5.6), direction: .right, color: color)

            let bottom = UIBezierPath()
            bottom.lineWidth = 2.15
            bottom.lineCapStyle = .round
            bottom.lineJoinStyle = .round
            bottom.move(to: CGPoint(x: 19.8, y: 14.8))
            bottom.addCurve(
                to: CGPoint(x: 16, y: 18.4),
                controlPoint1: CGPoint(x: 19.8, y: 16.8),
                controlPoint2: CGPoint(x: 18.1, y: 18.4)
            )
            bottom.addLine(to: CGPoint(x: 5.4, y: 18.4))
            bottom.stroke()
            arrowHead(at: CGPoint(x: 3, y: 18.4), direction: .left, color: color)
        }
    }

    private enum ArrowDirection { case left, right }

    private static func arrowHead(at point: CGPoint, direction: ArrowDirection, color: UIColor) {
        let path = UIBezierPath()
        if direction == .right {
            path.move(to: CGPoint(x: point.x - 4.2, y: point.y - 3.6))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x - 4.2, y: point.y + 3.6))
        } else {
            path.move(to: CGPoint(x: point.x + 4.2, y: point.y - 3.6))
            path.addLine(to: point)
            path.addLine(to: CGPoint(x: point.x + 4.2, y: point.y + 3.6))
        }
        path.close()
        color.setFill()
        path.fill()
    }

    private static func draw(size: CGSize, drawing: (UIColor) -> Void) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        let color = UIColor.black
        drawing(color)
        let image = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        return image.withRenderingMode(.alwaysTemplate)
    }
}

extension UIView {
    func pinEdges(to other: UIView, insets: UIEdgeInsets = .zero) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: other.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -insets.bottom)
        ])
    }
}

extension UIColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1.0) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: alpha
        )
    }

    fileprivate var matchesSemanticPrimary: Bool {
        return matchesAny([UIColor(hex: 0x121214), UIColor(hex: 0xF4F4F7), UIColor(white: 0.06, alpha: 1)])
    }

    fileprivate var matchesSemanticSecondary: Bool {
        return matchesAny([UIColor(hex: 0x74747A), UIColor(hex: 0x98989F), UIColor(white: 0.46, alpha: 1), UIColor(white: 0.67, alpha: 1)])
    }

    fileprivate var matchesSemanticSeparator: Bool {
        return matchesAny([UIColor(hex: 0xE5E5EA), UIColor(hex: 0x2A2A2F), UIColor(white: 0.88, alpha: 1)])
    }

    fileprivate func matchesAny(_ colors: [UIColor]) -> Bool {
        return colors.contains { isApproximatelyEqual(to: $0) }
    }

    private func isApproximatelyEqual(to other: UIColor) -> Bool {
        var lhs: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var rhs: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        guard getRed(&lhs.0, green: &lhs.1, blue: &lhs.2, alpha: &lhs.3),
              other.getRed(&rhs.0, green: &rhs.1, blue: &rhs.2, alpha: &rhs.3) else { return false }
        return abs(lhs.0 - rhs.0) < 0.01
            && abs(lhs.1 - rhs.1) < 0.01
            && abs(lhs.2 - rhs.2) < 0.01
            && abs(lhs.3 - rhs.3) < 0.01
    }
}
