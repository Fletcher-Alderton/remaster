import UIKit

final class SettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate {
    var onConfigurationChanged: (([SettingsTabItem]) -> Void)?

    var onLastFMChanged: ((String?) -> Void)?
    var onAppearanceChanged: ((AppearanceMode) -> Void)?

    var onQobuzAccountAction: (() -> Void)?
    var onQualityChanged: ((QobuzStreamQuality) -> Void)?
    var onDismissSwipe: (() -> Void)?

    private var items: [SettingsTabItem]
    private var lastFMUsername: String?
    private var appearanceMode: AppearanceMode
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let titleLabel = UILabel()
    private let appearanceGroup = UIView()
    private let appearanceControl = UISegmentedControl(items: AppearanceMode.allCases.map { $0.title })
    private let tabsTable = UITableView(frame: .zero, style: .plain)

    private let qobuzGroup = UIView()
    private let qobuzTestButton = UIButton(type: .system)
    private let qualityControl = UISegmentedControl(items: QobuzStreamQuality.allCases.map(\.title))
    private let scrobblingGroup = UIView()
    private let lastFMField = UITextField()
    private let lastFMButton = UIButton(type: .system)
    private var tabsHeight: NSLayoutConstraint!
    private var dragSource: IndexPath?

    init(items: [SettingsTabItem], lastFMUsername: String?, appearanceMode: AppearanceMode) {
        self.items = items
        self.lastFMUsername = lastFMUsername
        self.appearanceMode = appearanceMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var prefersStatusBarHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildView()
        configureLastFM()
        configureGestures()
    }

    func update(items: [SettingsTabItem], lastFMUsername: String?) {
        self.items = items
        self.lastFMUsername = lastFMUsername
        tabsHeight.constant = CGFloat(items.count) * 42
        tabsTable.reloadData()
        configureLastFM()
    }


    private func buildView() {
        view.accessibilityIdentifier = "settings"
        view.backgroundColor = DesignSystem.settingsBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.text = "Settings"
        titleLabel.font = DesignSystem.font(22, weight: .bold)
        titleLabel.textColor = DesignSystem.primaryText
        contentView.addSubview(titleLabel)

        let appearanceSection = sectionLabel("Appearance")
        contentView.addSubview(appearanceSection)
        configure(group: appearanceGroup)
        contentView.addSubview(appearanceGroup)
        appearanceControl.translatesAutoresizingMaskIntoConstraints = false
        appearanceControl.selectedSegmentIndex = AppearanceMode.allCases.firstIndex(of: appearanceMode) ?? 2
        appearanceControl.tintColor = DesignSystem.accent
        appearanceControl.accessibilityIdentifier = "settings.appearance"
        appearanceControl.addTarget(self, action: #selector(appearanceChanged), for: .valueChanged)
        appearanceGroup.addSubview(appearanceControl)

        let tabsSection = sectionLabel("Library Tabs")
        contentView.addSubview(tabsSection)
        tabsTable.translatesAutoresizingMaskIntoConstraints = false
        tabsTable.dataSource = self
        tabsTable.delegate = self
        tabsTable.rowHeight = 42
        tabsTable.isScrollEnabled = false
        tabsTable.backgroundColor = DesignSystem.pageBackground
        tabsTable.separatorColor = DesignSystem.separator
        tabsTable.layer.cornerRadius = 8
        tabsTable.layer.borderWidth = 0.5
        tabsTable.layer.borderColor = DesignSystem.separator.cgColor
        tabsTable.register(SettingsTabCell.self, forCellReuseIdentifier: SettingsTabCell.reuseIdentifier)
        contentView.addSubview(tabsTable)
        tabsHeight = tabsTable.heightAnchor.constraint(equalToConstant: CGFloat(items.count) * 42)


        let qobuzSection = sectionLabel("Qobuz Account & Audio Quality")
        contentView.addSubview(qobuzSection)
        configure(group: qobuzGroup)
        contentView.addSubview(qobuzGroup)
        qobuzTestButton.translatesAutoresizingMaskIntoConstraints = false
        qobuzTestButton.setTitle("Account: \(QobuzCredentialStore.shared.load() == nil ? "Not signed in" : "Manage")", for: .normal)
        qobuzTestButton.setTitleColor(DesignSystem.accent, for: .normal)
        qobuzTestButton.titleLabel?.font = DesignSystem.font(10, weight: .semibold)
        qobuzTestButton.addTarget(self, action: #selector(qobuzTestTapped), for: .touchUpInside)
        qobuzGroup.addSubview(qobuzTestButton)
        qualityControl.translatesAutoresizingMaskIntoConstraints = false
        qualityControl.selectedSegmentIndex = QobuzStreamQuality.allCases.firstIndex(of: QobuzPreferences.quality) ?? 1
        qualityControl.tintColor = DesignSystem.accent
        qualityControl.accessibilityIdentifier = "settings.qobuzQuality"
        qualityControl.addTarget(self, action: #selector(qualityChanged), for: .valueChanged)
        qobuzGroup.addSubview(qualityControl)

        let scrobblingSection = sectionLabel("Scrobbling")
        contentView.addSubview(scrobblingSection)
        configure(group: scrobblingGroup)
        contentView.addSubview(scrobblingGroup)
        lastFMField.translatesAutoresizingMaskIntoConstraints = false
        lastFMField.placeholder = "Last.fm username"
        lastFMField.font = DesignSystem.font(11)
        lastFMField.backgroundColor = DesignSystem.controlFill
        lastFMField.layer.cornerRadius = 6
        lastFMField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        lastFMField.leftViewMode = .always
        lastFMField.delegate = self
        lastFMButton.translatesAutoresizingMaskIntoConstraints = false
        style(actionButton: lastFMButton, title: "Sign In")
        lastFMButton.addTarget(self, action: #selector(lastFMTapped), for: .touchUpInside)
        scrobblingGroup.addSubview(lastFMField)
        scrobblingGroup.addSubview(lastFMButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: view.widthAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 34),
            appearanceSection.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            appearanceSection.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 20),
            appearanceGroup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            appearanceGroup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            appearanceGroup.topAnchor.constraint(equalTo: appearanceSection.bottomAnchor, constant: 6),
            appearanceGroup.heightAnchor.constraint(equalToConstant: 44),
            appearanceControl.leadingAnchor.constraint(equalTo: appearanceGroup.leadingAnchor, constant: 8),
            appearanceControl.trailingAnchor.constraint(equalTo: appearanceGroup.trailingAnchor, constant: -8),
            appearanceControl.centerYAnchor.constraint(equalTo: appearanceGroup.centerYAnchor),
            tabsSection.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            tabsSection.topAnchor.constraint(equalTo: appearanceGroup.bottomAnchor, constant: 18),
            tabsTable.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            tabsTable.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            tabsTable.topAnchor.constraint(equalTo: tabsSection.bottomAnchor, constant: 6),
            tabsHeight,


            qobuzSection.leadingAnchor.constraint(equalTo: tabsSection.leadingAnchor),
            qobuzSection.topAnchor.constraint(equalTo: tabsTable.bottomAnchor, constant: 18),
            qobuzGroup.leadingAnchor.constraint(equalTo: tabsTable.leadingAnchor),
            qobuzGroup.trailingAnchor.constraint(equalTo: tabsTable.trailingAnchor),
            qobuzGroup.topAnchor.constraint(equalTo: qobuzSection.bottomAnchor, constant: 6),
            qobuzGroup.heightAnchor.constraint(equalToConstant: 80),
            qobuzTestButton.leadingAnchor.constraint(equalTo: qobuzGroup.leadingAnchor, constant: 10),
            qobuzTestButton.topAnchor.constraint(equalTo: qobuzGroup.topAnchor, constant: 7),
            qualityControl.leadingAnchor.constraint(equalTo: qobuzGroup.leadingAnchor, constant: 8),
            qualityControl.trailingAnchor.constraint(equalTo: qobuzGroup.trailingAnchor, constant: -8),
            qualityControl.bottomAnchor.constraint(equalTo: qobuzGroup.bottomAnchor, constant: -7),

            scrobblingSection.leadingAnchor.constraint(equalTo: tabsSection.leadingAnchor),
            scrobblingSection.topAnchor.constraint(equalTo: qobuzGroup.bottomAnchor, constant: 18),
            scrobblingGroup.leadingAnchor.constraint(equalTo: tabsTable.leadingAnchor),
            scrobblingGroup.trailingAnchor.constraint(equalTo: tabsTable.trailingAnchor),
            scrobblingGroup.topAnchor.constraint(equalTo: scrobblingSection.bottomAnchor, constant: 6),
            scrobblingGroup.heightAnchor.constraint(equalToConstant: 54),
            scrobblingGroup.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -45),
            lastFMField.leadingAnchor.constraint(equalTo: scrobblingGroup.leadingAnchor, constant: 10),
            lastFMField.trailingAnchor.constraint(equalTo: lastFMButton.leadingAnchor, constant: -6),
            lastFMField.centerYAnchor.constraint(equalTo: scrobblingGroup.centerYAnchor),
            lastFMField.heightAnchor.constraint(equalToConstant: 34),
            lastFMButton.trailingAnchor.constraint(equalTo: scrobblingGroup.trailingAnchor, constant: -9),
            lastFMButton.centerYAnchor.constraint(equalTo: scrobblingGroup.centerYAnchor)
        ])
    }

    private func configureGestures() {
        let dismiss = UIPanGestureRecognizer(target: self, action: #selector(swipedFromLeftEdge(_:)))
        dismiss.delegate = self
        dismiss.cancelsTouchesInView = false
        view.addGestureRecognizer(dismiss)
        let reorder = UILongPressGestureRecognizer(target: self, action: #selector(handleReorder(_:)))
        reorder.minimumPressDuration = 0.18
        tabsTable.addGestureRecognizer(reorder)
    }

    private func sectionLabel(_ title: String) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = title.uppercased()
        label.font = DesignSystem.font(8, weight: .semibold)
        label.textColor = DesignSystem.secondaryText
        return label
    }


    private func configure(group: UIView) {
        group.translatesAutoresizingMaskIntoConstraints = false
        group.backgroundColor = DesignSystem.pageBackground
        group.layer.cornerRadius = 8
        group.layer.borderWidth = 0.5
        group.layer.borderColor = DesignSystem.separator.cgColor
    }


    private func style(actionButton: UIButton, title: String) {
        actionButton.setTitle(title, for: .normal)
        actionButton.setTitleColor(DesignSystem.accent, for: .normal)
        actionButton.titleLabel?.font = DesignSystem.font(10, weight: .semibold)
        actionButton.backgroundColor = DesignSystem.actionFill
        actionButton.layer.cornerRadius = 6
        actionButton.contentEdgeInsets = UIEdgeInsets(top: 7, left: 10, bottom: 7, right: 10)
    }

    private func configureLastFM() {
        guard isViewLoaded else { return }
        if let username = lastFMUsername, !username.isEmpty {
            lastFMField.text = username
            lastFMField.isEnabled = false
            style(actionButton: lastFMButton, title: "Sign Out")
        } else {
            lastFMField.text = nil
            lastFMField.isEnabled = true
            style(actionButton: lastFMButton, title: "Sign In")
        }
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { return items.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = items[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: SettingsTabCell.reuseIdentifier, for: indexPath) as! SettingsTabCell
        cell.configure(title: item.title, detail: item.note, enabled: item.isEnabled)
        cell.onEnabledChanged = { [weak self] enabled in self?.setEnabled(enabled, at: indexPath.row) }
        return cell
    }

    private func setEnabled(_ enabled: Bool, at index: Int) {
        guard items.indices.contains(index) else { return }
        let enabledCount = items.filter { $0.isEnabled }.count
        if !enabled && enabledCount == 1 {
            tabsTable.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
            return
        }
        if enabled && enabledCount >= TabConfiguration.maximumTabs {
            tabsTable.reloadRows(at: [IndexPath(row: index, section: 0)], with: .none)
            return
        }
        items[index].isEnabled = enabled
        notifyConfiguration()
    }

    private func notifyConfiguration() {
        onConfigurationChanged?(items)
        tabsTable.reloadData()
    }

    @objc private func handleReorder(_ recognizer: UILongPressGestureRecognizer) {
        let location = recognizer.location(in: tabsTable)
        switch recognizer.state {
        case .began:
            guard let indexPath = tabsTable.indexPathForRow(at: location), items[indexPath.row].isEnabled else { return }
            dragSource = indexPath
            if let cell = tabsTable.cellForRow(at: indexPath) {
                UIView.animate(
                    withDuration: 0.10,
                    animations: {
                        cell.transform = CGAffineTransform(scaleX: 0.985, y: 0.985)
                        cell.alpha = 0.72
                    }
                )
            }
        case .changed:
            guard let source = dragSource,
                  let destination = tabsTable.indexPathForRow(at: location),
                  source != destination,
                  items[destination.row].isEnabled else { return }
            let moved = items.remove(at: source.row)
            items.insert(moved, at: destination.row)
            tabsTable.moveRow(at: source, to: destination)
            dragSource = destination
        case .ended:
            if let source = dragSource, let cell = tabsTable.cellForRow(at: source) {
                InteractionMotion.setRow(cell, highlighted: false)
            }
            if dragSource != nil { notifyConfiguration() }
            dragSource = nil
        default:
            if let source = dragSource, let cell = tabsTable.cellForRow(at: source) {
                InteractionMotion.setRow(cell, highlighted: false)
            }
            tabsTable.reloadData()
            dragSource = nil
        }
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        return items[indexPath.row].isEnabled
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        let moved = items.remove(at: sourceIndexPath.row)
        items.insert(moved, at: destinationIndexPath.row)
        notifyConfiguration()
    }


    @objc private func appearanceChanged() {
        guard AppearanceMode.allCases.indices.contains(appearanceControl.selectedSegmentIndex) else { return }
        appearanceMode = AppearanceMode.allCases[appearanceControl.selectedSegmentIndex]
        onAppearanceChanged?(appearanceMode)
    }

    @objc private func qobuzTestTapped() { onQobuzAccountAction?() }

    @objc private func qualityChanged() {
        guard QobuzStreamQuality.allCases.indices.contains(qualityControl.selectedSegmentIndex) else { return }
        onQualityChanged?(QobuzStreamQuality.allCases[qualityControl.selectedSegmentIndex])
    }

    @objc private func lastFMTapped() {
        if lastFMUsername != nil {
            lastFMUsername = nil
            onLastFMChanged?(nil)
            configureLastFM()
            return
        }
        let username = lastFMField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !username.isEmpty else {
            lastFMField.becomeFirstResponder()
            return
        }
        lastFMUsername = username
        onLastFMChanged?(username)
        configureLastFM()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        lastFMTapped()
        textField.resignFirstResponder()
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = (gestureRecognizer as? UIPanGestureRecognizer)?.velocity(in: view) ?? .zero
        return velocity.x > abs(velocity.y)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let window = touch.window else { return false }
        return touch.location(in: window).x <= 24
    }

    @objc private func swipedFromLeftEdge(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended, gesture.translation(in: view).x > 45 else { return }
        onDismissSwipe?()
    }
}
