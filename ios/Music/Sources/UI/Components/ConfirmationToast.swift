import UIKit

enum ConfirmationToast {
    static func show(in hostView: UIView, action: SongSwipeAction, message: String) {
        hostView.viewWithTag(0x534F4E47)?.removeFromSuperview()

        let toast = UIVisualEffectView(effect: UIBlurEffect(style: ThemeManager.isDark ? .dark : .extraLight))
        toast.tag = 0x534F4E47
        toast.translatesAutoresizingMaskIntoConstraints = false
        toast.layer.cornerRadius = 14
        toast.layer.masksToBounds = true
        toast.layer.borderWidth = 0.5
        toast.layer.borderColor = DesignSystem.separator.cgColor
        toast.accessibilityIdentifier = "songAction.toast"
        toast.isAccessibilityElement = true
        toast.accessibilityLabel = message
        toast.accessibilityTraits = .staticText

        let icon = SongActionIconView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.action = action
        icon.backgroundColor = toastColor(for: action)
        icon.layer.cornerRadius = 11
        icon.layer.masksToBounds = true

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = message
        label.font = DesignSystem.font(11, weight: .semibold)
        label.textColor = DesignSystem.primaryText

        toast.contentView.addSubview(icon)
        toast.contentView.addSubview(label)
        hostView.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: hostView.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: hostView.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            toast.heightAnchor.constraint(equalToConstant: 38),
            icon.leadingAnchor.constraint(equalTo: toast.contentView.leadingAnchor, constant: 7),
            icon.centerYAnchor.constraint(equalTo: toast.contentView.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: toast.contentView.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: toast.contentView.centerYAnchor)
        ])

        toast.alpha = 0
        toast.transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.96, y: 0.96)
        UIView.animate(withDuration: 0.18, animations: {
            toast.alpha = 1
            toast.transform = .identity
        }, completion: { _ in
            UIAccessibility.post(notification: .announcement, argument: message)
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            UIView.animate(withDuration: 0.2, animations: {
                toast.alpha = 0
                toast.transform = CGAffineTransform(translationX: 0, y: 6)
            }, completion: { _ in toast.removeFromSuperview() })
        }
    }

    private static func toastColor(for action: SongSwipeAction) -> UIColor {
        switch action {
        case .enqueue, .playNext: return DesignSystem.accent
        case .toggleLike: return UIColor(red: 1, green: 0.30, blue: 0.39, alpha: 1)
        case .more: return UIColor(white: 0.48, alpha: 1)
        }
    }
}
