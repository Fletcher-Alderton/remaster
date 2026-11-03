import UIKit
import AVFoundation

final class SettingsViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UITextFieldDelegate, UIGestureRecognizerDelegate {
    var onConfigurationChanged: (([SettingsTabItem]) -> Void)?

    var onLastFMChanged: ((String?) -> Void)?
    var onAppearanceChanged: ((AppearanceMode) -> Void)?

    var onQobuzAccountAction: (() -> Void)?
    var onQualityChanged: ((QobuzStreamQuality) -> Void)?
    var onDismissSwipe: (() -> Void)?

    private var audioRouteObserver: NSObjectProtocol?

    deinit {
        if let observer = audioRouteObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = audioPathObserver { NotificationCenter.default.removeObserver(observer) }
    }

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
    private let qualityGuidance = UILabel()
    private let qualityControl = UISegmentedControl(items: QobuzStreamQuality.allCases.map(\.title))
    private let scrobblingGroup = UIView()
    private let lastFMField = UITextField()
    private let lastFMButton = UIButton(type: .system)

    private let audioPathGroup = UIView()
    private let sampleRateControl = UISegmentedControl(items: AudioSampleRateOption.allCases.map(\.title))
    private let audioPathSourceLabel = UILabel()
    private let audioPathEqualiserLabel = UILabel()
    private let audioPathVerdictLabel = UILabel()
    private let audioPathSampleRateLabel = UILabel()
    private let audioPathCaveatLabel = UILabel()
    private var audioPathObserver: NSObjectProtocol?

    private let eqStore: EQProfileStore
    private let eqTable = UITableView(frame: .zero, style: .plain)
    private let eqGroup = UIView()
    private let eqAddButton = UIButton(type: .system)
    private let eqGuidance = UILabel()
    private var eqProfiles: [EQProfile] = []
    private var eqHeight: NSLayoutConstraint!

    private var tabsHeight: NSLayoutConstraint!
    private var dragSource: IndexPath?

    init(items: [SettingsTabItem], lastFMUsername: String?, appearanceMode: AppearanceMode,
         eqStore: EQProfileStore = .shared) {
        self.items = items
        self.lastFMUsername = lastFMUsername
        self.appearanceMode = appearanceMode
        self.eqStore = eqStore
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
        refreshEQProfiles()
        refreshAudioPath()
        audioPathObserver = NotificationCenter.default.addObserver(
            forName: AudioPathMonitor.didChange, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshAudioPath() }
        audioRouteObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in self?.refreshQobuz() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshQobuz()
        refreshEQProfiles()
        refreshAudioPath()
    }

    private func refreshQobuz() {
        qobuzTestButton.setTitle(QobuzCredentialStore.shared.load() == nil ? "Not signed in · Sign In" : "Signed in · Manage Account", for: .normal)
        qualityControl.selectedSegmentIndex = QobuzStreamQuality.allCases.firstIndex(of: QobuzPreferences.quality) ?? 1
        qualityGuidance.text = QobuzPreferences.requestedQualityGuidance
    }

    /// Re-reads the measured audio path and writes it into the section.
    private func refreshAudioPath() {
        guard isViewLoaded else { return }
        AudioPathMonitor.shared.refreshEqualiserState(publish: false)
        let report = AudioPathMonitor.shared.snapshot()

        audioPathSourceLabel.text = AudioPathFormatting.sourceLine(report)
        audioPathEqualiserLabel.text = AudioPathFormatting.equaliserLine(report)
        let verdict = AudioPathFormatting.verdictLine(report)
        audioPathVerdictLabel.text = verdict
        audioPathVerdictLabel.isHidden = verdict.isEmpty
        audioPathSampleRateLabel.text = AudioPathFormatting.sampleRateLine(report)
        audioPathCaveatLabel.text = AudioPathFormatting.bitDepthCaveat
        sampleRateControl.selectedSegmentIndex =
            AudioSampleRateOption.allCases.firstIndex(of: AudioPathPreferences.shared.option) ?? 0
    }

    @objc private func sampleRateChanged() {
        guard AudioSampleRateOption.allCases.indices.contains(sampleRateControl.selectedSegmentIndex) else { return }
        let option = AudioSampleRateOption.allCases[sampleRateControl.selectedSegmentIndex]
        AudioPathPreferences.shared.option = option
        // Request it now so the next activation already has it; the report shows whether
        // the route takes it.
        AudioPathPreferences.shared.apply(to: AVAudioSession.sharedInstance())
        AudioPathMonitor.shared.refreshSession()
        refreshAudioPath()
        refreshQobuz()
    }

    /// Reloads the stored profiles and resizes the non-scrolling table to fit them.
    func refreshEQProfiles() {
        guard isViewLoaded else { return }
        eqProfiles = eqStore.profiles
        eqHeight?.constant = CGFloat(max(eqProfiles.count, 1)) * 44
        eqTable.reloadData()
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
        tabsTable.accessibilityIdentifier = "settings.tabs.table"
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
        qobuzTestButton.accessibilityIdentifier = "settings.qobuzAccount"
        qualityGuidance.translatesAutoresizingMaskIntoConstraints = false
        qualityGuidance.font = DesignSystem.font(11)
        qualityGuidance.textColor = DesignSystem.secondaryText
        qualityGuidance.numberOfLines = 0
        qualityGuidance.accessibilityIdentifier = "settings.qobuzQualityGuidance"
        qobuzGroup.addSubview(qualityGuidance)
        refreshQobuz()

        let audioPathSection = sectionLabel("Audio Path")
        contentView.addSubview(audioPathSection)
        configure(group: audioPathGroup)
        contentView.addSubview(audioPathGroup)

        sampleRateControl.translatesAutoresizingMaskIntoConstraints = false
        sampleRateControl.selectedSegmentIndex = AudioSampleRateOption.allCases.firstIndex(of: AudioPathPreferences.shared.option) ?? 0
        sampleRateControl.tintColor = DesignSystem.accent
        sampleRateControl.accessibilityIdentifier = "settings.audioPath.sampleRate"
        sampleRateControl.addTarget(self, action: #selector(sampleRateChanged), for: .valueChanged)
        audioPathGroup.addSubview(sampleRateControl)

        let audioPathLabels = [audioPathSourceLabel, audioPathEqualiserLabel,
                               audioPathVerdictLabel, audioPathSampleRateLabel, audioPathCaveatLabel]
        for label in audioPathLabels {
            label.font = DesignSystem.font(10)
            label.textColor = DesignSystem.secondaryText
            label.numberOfLines = 0
        }
        audioPathSourceLabel.accessibilityIdentifier = "settings.audioPath.source"
        audioPathEqualiserLabel.accessibilityIdentifier = "settings.audioPath.equaliser"
        audioPathVerdictLabel.accessibilityIdentifier = "settings.audioPath.verdict"
        audioPathSampleRateLabel.accessibilityIdentifier = "settings.audioPath.sampleRateLabel"
        audioPathCaveatLabel.accessibilityIdentifier = "settings.audioPath.caveat"
        audioPathCaveatLabel.font = DesignSystem.font(9)

        let audioPathStack = UIStackView(arrangedSubviews: [audioPathSourceLabel,
                                                           audioPathEqualiserLabel,
                                                           audioPathVerdictLabel,
                                                           audioPathSampleRateLabel,
                                                           audioPathCaveatLabel])
        audioPathStack.axis = .vertical
        audioPathStack.spacing = 3
        audioPathStack.translatesAutoresizingMaskIntoConstraints = false
        audioPathGroup.addSubview(audioPathStack)

        let eqSection = sectionLabel("Parametric EQ")
        contentView.addSubview(eqSection)
        eqTable.translatesAutoresizingMaskIntoConstraints = false
        eqTable.dataSource = self
        eqTable.delegate = self
        eqTable.rowHeight = 44
        eqTable.isScrollEnabled = false
        eqTable.backgroundColor = DesignSystem.pageBackground
        eqTable.separatorColor = DesignSystem.separator
        eqTable.layer.cornerRadius = 8
        eqTable.layer.borderWidth = 0.5
        eqTable.layer.borderColor = DesignSystem.separator.cgColor
        eqTable.register(EQProfileCell.self, forCellReuseIdentifier: EQProfileCell.reuseIdentifier)
        eqTable.accessibilityIdentifier = "settings.eq.table"
        contentView.addSubview(eqTable)
        eqHeight = eqTable.heightAnchor.constraint(equalToConstant: 44)

        configure(group: eqGroup)
        contentView.addSubview(eqGroup)
        eqAddButton.translatesAutoresizingMaskIntoConstraints = false
        style(actionButton: eqAddButton, title: "Add Profile…")
        eqAddButton.accessibilityIdentifier = "settings.eq.add"
        eqAddButton.addTarget(self, action: #selector(addEQProfileTapped), for: .touchUpInside)
        eqGroup.addSubview(eqAddButton)
        eqGuidance.translatesAutoresizingMaskIntoConstraints = false
        eqGuidance.font = DesignSystem.font(10)
        eqGuidance.textColor = DesignSystem.secondaryText
        eqGuidance.numberOfLines = 0
        eqGuidance.accessibilityIdentifier = "settings.eq.guidance"
        eqGuidance.text = "Applies to Qobuz playback on this device. Enabled profiles combine; each switch adds its filters and preamp."
        eqGroup.addSubview(eqGuidance)

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
            qobuzTestButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            qobuzTestButton.trailingAnchor.constraint(lessThanOrEqualTo: qobuzGroup.trailingAnchor, constant: -10),
            qobuzTestButton.leadingAnchor.constraint(equalTo: qobuzGroup.leadingAnchor, constant: 10),
            qobuzTestButton.topAnchor.constraint(equalTo: qobuzGroup.topAnchor, constant: 7),
            qualityControl.leadingAnchor.constraint(equalTo: qobuzGroup.leadingAnchor, constant: 8),
            qualityControl.trailingAnchor.constraint(equalTo: qobuzGroup.trailingAnchor, constant: -8),
            qualityControl.topAnchor.constraint(equalTo: qobuzTestButton.bottomAnchor, constant: 4),
            qualityControl.heightAnchor.constraint(equalToConstant: 36),
            qualityGuidance.leadingAnchor.constraint(equalTo: qobuzGroup.leadingAnchor, constant: 10),
            qualityGuidance.trailingAnchor.constraint(equalTo: qobuzGroup.trailingAnchor, constant: -10),
            qualityGuidance.topAnchor.constraint(equalTo: qualityControl.bottomAnchor, constant: 10),
            qualityGuidance.bottomAnchor.constraint(equalTo: qobuzGroup.bottomAnchor, constant: -12),

            audioPathSection.leadingAnchor.constraint(equalTo: tabsSection.leadingAnchor),
            audioPathSection.topAnchor.constraint(equalTo: qobuzGroup.bottomAnchor, constant: 18),
            audioPathGroup.leadingAnchor.constraint(equalTo: tabsTable.leadingAnchor),
            audioPathGroup.trailingAnchor.constraint(equalTo: tabsTable.trailingAnchor),
            audioPathGroup.topAnchor.constraint(equalTo: audioPathSection.bottomAnchor, constant: 6),
            sampleRateControl.leadingAnchor.constraint(equalTo: audioPathGroup.leadingAnchor, constant: 8),
            sampleRateControl.trailingAnchor.constraint(equalTo: audioPathGroup.trailingAnchor, constant: -8),
            sampleRateControl.topAnchor.constraint(equalTo: audioPathGroup.topAnchor, constant: 8),
            sampleRateControl.heightAnchor.constraint(equalToConstant: 36),
            audioPathStack.leadingAnchor.constraint(equalTo: audioPathGroup.leadingAnchor, constant: 10),
            audioPathStack.trailingAnchor.constraint(equalTo: audioPathGroup.trailingAnchor, constant: -10),
            audioPathStack.topAnchor.constraint(equalTo: sampleRateControl.bottomAnchor, constant: 8),
            audioPathStack.bottomAnchor.constraint(equalTo: audioPathGroup.bottomAnchor, constant: -12),

            eqSection.leadingAnchor.constraint(equalTo: tabsSection.leadingAnchor),
            eqSection.topAnchor.constraint(equalTo: audioPathGroup.bottomAnchor, constant: 18),
            eqTable.leadingAnchor.constraint(equalTo: tabsTable.leadingAnchor),
            eqTable.trailingAnchor.constraint(equalTo: tabsTable.trailingAnchor),
            eqTable.topAnchor.constraint(equalTo: eqSection.bottomAnchor, constant: 6),
            eqHeight,
            eqGroup.leadingAnchor.constraint(equalTo: tabsTable.leadingAnchor),
            eqGroup.trailingAnchor.constraint(equalTo: tabsTable.trailingAnchor),
            eqGroup.topAnchor.constraint(equalTo: eqTable.bottomAnchor, constant: 6),
            eqAddButton.leadingAnchor.constraint(equalTo: eqGroup.leadingAnchor, constant: 10),
            eqAddButton.topAnchor.constraint(equalTo: eqGroup.topAnchor, constant: 8),
            eqAddButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
            eqGuidance.leadingAnchor.constraint(equalTo: eqGroup.leadingAnchor, constant: 10),
            eqGuidance.trailingAnchor.constraint(equalTo: eqGroup.trailingAnchor, constant: -10),
            eqGuidance.topAnchor.constraint(equalTo: eqAddButton.bottomAnchor, constant: 8),
            eqGuidance.bottomAnchor.constraint(equalTo: eqGroup.bottomAnchor, constant: -10),

            scrobblingSection.leadingAnchor.constraint(equalTo: tabsSection.leadingAnchor),
            scrobblingSection.topAnchor.constraint(equalTo: eqGroup.bottomAnchor, constant: 18),
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

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if tableView === eqTable { return max(eqProfiles.count, 1) }
        return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if tableView === eqTable {
            if eqProfiles.indices.contains(indexPath.row) {
                let profile = eqProfiles[indexPath.row]
                let cell = tableView.dequeueReusableCell(withIdentifier: EQProfileCell.reuseIdentifier, for: indexPath) as! EQProfileCell
                cell.configure(name: profile.name, summary: profile.summaryText, enabled: profile.isEnabled)
                cell.onEnabledChanged = { [weak self] enabled in
                    self?.setEQEnabled(enabled, at: indexPath.row)
                }
                return cell
            }
            let placeholder = tableView.dequeueReusableCell(withIdentifier: EQProfileCell.reuseIdentifier, for: indexPath) as! EQProfileCell
            placeholder.configureAsPlaceholder(name: "No profiles loaded",
                                               summary: "Tap Add Profile to paste an Equalizer APO profile")
            return placeholder
        }
        let item = items[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: SettingsTabCell.reuseIdentifier, for: indexPath) as! SettingsTabCell
        cell.configure(title: item.title, detail: item.note, enabled: item.isEnabled)
        cell.onEnabledChanged = { [weak self] enabled in self?.setEnabled(enabled, at: indexPath.row) }
        return cell
    }

    private func setEQEnabled(_ enabled: Bool, at index: Int) {
        guard eqProfiles.indices.contains(index) else { return }
        eqStore.setEnabled(enabled, id: eqProfiles[index].id)
        refreshEQProfiles()
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
        guard tableView === tabsTable, items.indices.contains(indexPath.row) else { return false }
        return items[indexPath.row].isEnabled
    }

    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard tableView === tabsTable else { return }
        let moved = items.remove(at: sourceIndexPath.row)
        items.insert(moved, at: destinationIndexPath.row)
        notifyConfiguration()
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard tableView === eqTable else { return }
        tableView.deselectRow(at: indexPath, animated: true)
        guard eqProfiles.indices.contains(indexPath.row) else { return }
        let detail = EQProfileDetailViewController(profile: eqProfiles[indexPath.row])
        let nav = UINavigationController(rootViewController: detail)
        nav.modalPresentationStyle = .fullScreen
        nav.navigationBar.barTintColor = DesignSystem.settingsBackground
        present(nav, animated: true)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath)
        -> UISwipeActionsConfiguration? {
        guard tableView === eqTable, eqProfiles.indices.contains(indexPath.row) else { return nil }
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completed in
            guard let self = self, self.eqProfiles.indices.contains(indexPath.row) else {
                completed(false)
                return
            }
            self.eqStore.remove(id: self.eqProfiles[indexPath.row].id)
            self.refreshEQProfiles()
            completed(true)
        }
        return UISwipeActionsConfiguration(actions: [delete])
    }

    @objc private func addEQProfileTapped() {
        let editor = EQProfileEditorViewController()
        editor.onSave = { [weak self] profile in
            guard let self = self else { return }
            self.eqStore.add(profile)
            self.refreshEQProfiles()
        }
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        nav.navigationBar.barTintColor = DesignSystem.settingsBackground
        present(nav, animated: true)
    }


    @objc private func appearanceChanged() {
        guard AppearanceMode.allCases.indices.contains(appearanceControl.selectedSegmentIndex) else { return }
        appearanceMode = AppearanceMode.allCases[appearanceControl.selectedSegmentIndex]
        onAppearanceChanged?(appearanceMode)
    }

    @objc private func qobuzTestTapped() { onQobuzAccountAction?() }

    @objc private func qualityChanged() {
        guard QobuzStreamQuality.allCases.indices.contains(qualityControl.selectedSegmentIndex) else { return }
        let quality = QobuzStreamQuality.allCases[qualityControl.selectedSegmentIndex]
        QobuzPreferences.quality = quality
        refreshQobuz()
        onQualityChanged?(quality)
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
