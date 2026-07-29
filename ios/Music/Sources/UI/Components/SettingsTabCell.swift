import UIKit

final class SettingsTabCell: UITableViewCell {
    static let reuseIdentifier = "SettingsTabCell"

    let dragHandle = UIImageView()
    let titleLabel = UILabel()
    let detailLabel = UILabel()
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
        titleLabel.text = nil
        detailLabel.text = nil
        detailLabel.isHidden = true
        onEnabledChanged = nil
    }

    func configure(title: String, detail: String? = nil, enabled: Bool) {
        titleLabel.text = title
        detailLabel.text = detail
        detailLabel.isHidden = detail == nil
        enabledSwitch.isOn = enabled
    }

    private func configureView() {
        selectionStyle = .none
        backgroundColor = DesignSystem.pageBackground
        contentView.backgroundColor = DesignSystem.pageBackground

        dragHandle.image = SettingsTabCell.dragHandleImage
        dragHandle.tintColor = UIColor(hex: 0xA5A5AC)
        dragHandle.contentMode = .center
        dragHandle.isUserInteractionEnabled = false
        dragHandle.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = DesignSystem.font(13)
        titleLabel.textColor = DesignSystem.primaryText
        detailLabel.font = DesignSystem.font(9)
        detailLabel.textColor = DesignSystem.secondaryText
        detailLabel.numberOfLines = 1
        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false

        enabledSwitch.onTintColor = DesignSystem.accent
        enabledSwitch.addTarget(self, action: #selector(didChangeEnabled), for: .valueChanged)
        enabledSwitch.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(dragHandle)
        contentView.addSubview(labels)
        contentView.addSubview(enabledSwitch)
        NSLayoutConstraint.activate([
            contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 42),
            dragHandle.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            dragHandle.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            dragHandle.widthAnchor.constraint(equalToConstant: 18),
            dragHandle.heightAnchor.constraint(equalToConstant: 18),
            labels.leadingAnchor.constraint(equalTo: dragHandle.trailingAnchor, constant: 10),
            labels.trailingAnchor.constraint(equalTo: enabledSwitch.leadingAnchor, constant: -10),
            labels.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            enabledSwitch.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            enabledSwitch.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    private static let dragHandleImage: UIImage? = {
        let size = CGSize(width: 12, height: 14)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        defer { UIGraphicsEndImageContext() }
        guard let context = UIGraphicsGetCurrentContext() else { return nil }
        context.setFillColor(UIColor.black.cgColor)
        for row in 0..<3 {
            context.fill(CGRect(x: 1, y: CGFloat(row) * 5 + 1, width: 10, height: 2))
        }
        return UIGraphicsGetImageFromCurrentImageContext()?.withRenderingMode(.alwaysTemplate)
    }()

    @objc private func didChangeEnabled() {
        onEnabledChanged?(enabledSwitch.isOn)
    }
}
