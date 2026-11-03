import UIKit

/// One EQ profile row: name, a short summary, and the profile's on/off switch.
///
/// Deliberately not a reuse of `SettingsTabCell`, which hard-codes a reorder handle and
/// a non-selectable style. The fonts, colours and switch metrics match it.
final class EQProfileCell: UITableViewCell {
    static let reuseIdentifier = "EQProfileCell"

    private let nameLabel = UILabel()
    private let summaryLabel = UILabel()
    let enabledSwitch = UISwitch()
    var onEnabledChanged: ((Bool) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        nameLabel.text = nil
        summaryLabel.text = nil
        // The empty-state row hides the switch; a recycled cell must show it again.
        enabledSwitch.isHidden = false
        enabledSwitch.isOn = false
        selectionStyle = .default
        onEnabledChanged = nil
    }

    func configure(name: String, summary: String, enabled: Bool) {
        nameLabel.text = name
        summaryLabel.text = summary
        enabledSwitch.isOn = enabled
    }

    /// The empty-state row has nothing to toggle and nothing to open.
    func configureAsPlaceholder(name: String, summary: String) {
        nameLabel.text = name
        summaryLabel.text = summary
        enabledSwitch.isHidden = true
        selectionStyle = .none
        onEnabledChanged = nil
    }

    private func configureView() {
        selectionStyle = .default
        backgroundColor = DesignSystem.pageBackground
        contentView.backgroundColor = DesignSystem.pageBackground

        nameLabel.font = DesignSystem.font(13)
        nameLabel.textColor = DesignSystem.primaryText
        summaryLabel.font = DesignSystem.font(9)
        summaryLabel.textColor = DesignSystem.secondaryText
        summaryLabel.numberOfLines = 1

        let labels = UIStackView(arrangedSubviews: [nameLabel, summaryLabel])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        enabledSwitch.onTintColor = DesignSystem.accent
        enabledSwitch.accessibilityIdentifier = "settings.eq.profileSwitch"
        enabledSwitch.addTarget(self, action: #selector(didChangeEnabled), for: .valueChanged)
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(labels)
        contentView.addSubview(enabledSwitch)
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            labels.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: enabledSwitch.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            enabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            enabledSwitch.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    @objc private func didChangeEnabled() {
        onEnabledChanged?(enabledSwitch.isOn)
    }
}
