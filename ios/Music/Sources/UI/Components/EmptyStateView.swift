import UIKit

final class EmptyStateView: UIView {
    let titleLabel = UILabel()
    let messageLabel = UILabel()
    let actionButton = UIButton(type: .system)
    var onAction: (() -> Void)?

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureView()
    }

    convenience init(message: String) {
        self.init(frame: .zero)
        configure(title: message)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func configure(title: String, message: String? = nil, actionTitle: String? = nil) {
        titleLabel.text = title
        messageLabel.text = message
        messageLabel.isHidden = message == nil
        actionButton.setTitle(actionTitle, for: .normal)
        actionButton.isHidden = actionTitle == nil
    }

    private func configureView() {
        backgroundColor = .clear
        titleLabel.font = DesignSystem.font(14, weight: .medium)
        titleLabel.textColor = DesignSystem.secondaryText
        titleLabel.textAlignment = .center
        messageLabel.font = DesignSystem.font(10)
        messageLabel.textColor = DesignSystem.secondaryText
        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        actionButton.titleLabel?.font = DesignSystem.font(12, weight: .semibold)
        actionButton.setTitleColor(DesignSystem.accent, for: .normal)
        actionButton.addTarget(self, action: #selector(didTapAction), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [titleLabel, messageLabel, actionButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @objc private func didTapAction() {
        onAction?()
    }
}
