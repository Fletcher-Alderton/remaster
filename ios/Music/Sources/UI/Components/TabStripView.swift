import UIKit

final class TabStripView: UIView {
    var onSelectionChanged: ((Int) -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let underline = UIView()
    private var buttons: [UIButton] = []
    private var underlineLeading: NSLayoutConstraint?
    private var underlineWidth: NSLayoutConstraint?
    private var hasSelection = true
    private var lastLayoutSize: CGSize = .zero

    private(set) var titles: [String] = []
    private(set) var selectedIndex: Int = 0

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func configure(titles: [String], selectedIndex: Int = 0) {
        self.titles = Array(titles.prefix(TabConfiguration.maximumTabs))
        buttons.forEach { $0.removeFromSuperview() }
        buttons.removeAll()

        for (index, title) in self.titles.enumerated() {
            let button = UIButton(type: .system)
            button.setTitle(title, for: .normal)
            button.titleLabel?.font = DesignSystem.font(12, weight: .semibold)
            button.setTitleColor(DesignSystem.secondaryText, for: .normal)
            button.accessibilityIdentifier = "tab.\(title.lowercased())"
            button.accessibilityLabel = title
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
            button.tag = index
            button.addTarget(self, action: #selector(didTapTab(_:)), for: .touchUpInside)
            stackView.addArrangedSubview(button)
            buttons.append(button)
        }

        setSelectedIndex(min(max(0, selectedIndex), max(0, buttons.count - 1)), animated: false, notify: false)
    }

    func setSelectedIndex(_ index: Int, animated: Bool = true, notify: Bool = false) {
        guard buttons.indices.contains(index) else { return }
        hasSelection = true
        selectedIndex = index
        buttons.enumerated().forEach { offset, button in
            button.setTitleColor(offset == index ? DesignSystem.accent : DesignSystem.secondaryText, for: .normal)
            button.accessibilityTraits = offset == index ? [.button, .selected] : .button
        }
        layoutIfNeeded()
        guard let button = buttons[safe: index] else { return }
        underlineLeading?.constant = button.frame.minX
        underlineWidth?.constant = button.bounds.width
        let updates = { self.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.22, animations: updates)
        } else {
            updates()
        }
        scrollView.scrollRectToVisible(button.frame, animated: animated)
        if notify { onSelectionChanged?(index) }
    }

    func clearSelection(animated: Bool = true) {
        hasSelection = false
        buttons.forEach {
            $0.setTitleColor(DesignSystem.secondaryText, for: .normal)
            $0.accessibilityTraits = .button
        }
        underlineWidth?.constant = 0
        let updates = { self.layoutIfNeeded() }
        if animated {
            UIView.animate(withDuration: 0.2, animations: updates)
        } else {
            updates()
        }
    }

    func applyTheme() {
        backgroundColor = DesignSystem.pageBackground
        underline.backgroundColor = DesignSystem.accent
        buttons.enumerated().forEach { index, button in
            let selected = hasSelection && index == selectedIndex
            button.setTitleColor(selected ? DesignSystem.accent : DesignSystem.secondaryText, for: .normal)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard hasSelection else {
            underlineWidth?.constant = 0
            return
        }
        guard let button = buttons[safe: selectedIndex] else { return }
        underlineLeading?.constant = button.frame.minX
        underlineWidth?.constant = button.bounds.width
        if lastLayoutSize != bounds.size {
            lastLayoutSize = bounds.size
            scrollView.scrollRectToVisible(button.frame, animated: false)
        }
    }

    private func configureView() {
        backgroundColor = DesignSystem.pageBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        addSubview(scrollView)
        stackView.axis = .horizontal
        stackView.distribution = .fillEqually
        stackView.alignment = .fill
        stackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stackView)

        underline.backgroundColor = DesignSystem.accent
        underline.layer.cornerRadius = 1
        underline.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(underline)

        underlineLeading = underline.leadingAnchor.constraint(equalTo: stackView.leadingAnchor)
        underlineWidth = underline.widthAnchor.constraint(equalToConstant: 0)
        // Fill available width when labels fit (375 pt), otherwise allow horizontal
        // scrolling instead of squeezing five labels on the 320 pt iPod display.
        let preferredWidth = stackView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
            stackView.widthAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.widthAnchor),
            preferredWidth,
            underline.heightAnchor.constraint(equalToConstant: 1.5),
            underline.bottomAnchor.constraint(equalTo: stackView.bottomAnchor),
            underlineLeading!, underlineWidth!
        ])
    }

    @objc private func didTapTab(_ sender: UIButton) {
        setSelectedIndex(sender.tag, notify: true)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        return indices.contains(index) ? self[index] : nil
    }
}
