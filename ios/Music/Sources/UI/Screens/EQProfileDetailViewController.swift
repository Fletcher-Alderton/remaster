import UIKit

/// Shows exactly what was parsed from a stored profile, including lines that could not
/// be used. Read-only: profiles are imported as text.
final class EQProfileDetailViewController: UIViewController, UITableViewDataSource {
    private let profile: EQProfile
    private let table = UITableView(frame: .zero, style: .grouped)

    init(profile: EQProfile) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.settingsBackground
        navigationItem.title = profile.name

        table.translatesAutoresizingMaskIntoConstraints = false
        table.dataSource = self
        table.backgroundColor = DesignSystem.settingsBackground
        table.separatorColor = DesignSystem.separator
        table.accessibilityIdentifier = "eq.detail.table"
        table.register(UITableViewCell.self, forCellReuseIdentifier: "eqFilter")
        view.addSubview(table)
        NSLayoutConstraint.activate([
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(doneTapped)
        )
    }

    @objc private func doneTapped() { dismiss(animated: true) }

    func numberOfSections(in tableView: UITableView) -> Int {
        profile.skippedLines.isEmpty ? 1 : 2
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? profile.filters.count : profile.skippedLines.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0
            ? String(format: "FILTERS (%d) · PREAMP %.1f dB", profile.filters.count, profile.preamp)
            : "SKIPPED LINES (\(profile.skippedLines.count))"
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else {
            return "These lines were not applied. Supported filters are PK, LSC, HSC, LS and HS."
        }
        let applied = profile.enabledFilterCount
        return applied == 0
            ? "Every filter is switched off, so this profile currently applies only its preamp."
            : "\(applied) of \(profile.filters.count) filters are applied. Profiles combine with every other enabled profile."
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "eqFilter", for: indexPath)
        cell.backgroundColor = DesignSystem.pageBackground
        cell.textLabel?.font = DesignSystem.font(11)
        cell.textLabel?.numberOfLines = 2
        cell.textLabel?.textColor = DesignSystem.primaryText
        cell.selectionStyle = .none

        if indexPath.section == 0, profile.filters.indices.contains(indexPath.row) {
            let filter = profile.filters[indexPath.row]
            cell.textLabel?.text = "\(filter.index) · \(filter.displayDescription)"
            cell.textLabel?.textColor = filter.isEnabled
                ? DesignSystem.primaryText
                : DesignSystem.secondaryText
        } else if profile.skippedLines.indices.contains(indexPath.row) {
            cell.textLabel?.text = profile.skippedLines[indexPath.row]
            cell.textLabel?.textColor = DesignSystem.secondaryText
        }
        return cell
    }
}
