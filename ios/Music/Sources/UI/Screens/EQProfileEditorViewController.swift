import UIKit

/// Pastes and names a parametric EQ profile, validating it before it is stored.
final class EQProfileEditorViewController: UIViewController, UITextViewDelegate, UITextFieldDelegate {
    /// Called with the parsed profile when the user saves. The caller stores it.
    var onSave: ((EQProfile) -> Void)?

    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let nameField = UITextField()
    private let textView = UITextView()
    private let pasteButton = UIButton(type: .system)
    private let hintLabel = UILabel()

    override var prefersStatusBarHidden: Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "eq.editor"
        view.backgroundColor = DesignSystem.settingsBackground
        buildView()
        updateSaveButton()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if textView.text.isEmpty { textView.becomeFirstResponder() }
    }

    private func buildView() {
        navigationItem.title = "Add EQ Profile"
        let cancel = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        cancel.accessibilityIdentifier = "eq.editor.cancel"
        navigationItem.leftBarButtonItem = cancel
        let save = UIBarButtonItem(barButtonSystemItem: .save, target: self, action: #selector(saveTapped))
        save.accessibilityIdentifier = "eq.editor.save"
        navigationItem.rightBarButtonItem = save
        navigationController?.navigationBar.tintColor = DesignSystem.accent
        navigationController?.navigationBar.titleTextAttributes = [.foregroundColor: DesignSystem.primaryText]
        navigationController?.navigationBar.barTintColor = DesignSystem.settingsBackground

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        scrollView.keyboardDismissMode = .interactive
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        scrollView.addSubview(contentView)

        let nameLabel = label("NAME", font: DesignSystem.font(8, weight: .semibold), colour: DesignSystem.secondaryText)
        contentView.addSubview(nameLabel)

        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholder = "e.g. Headphones"
        nameField.font = DesignSystem.font(13)
        nameField.textColor = DesignSystem.primaryText
        nameField.backgroundColor = DesignSystem.controlFill
        nameField.autocorrectionType = .no
        nameField.autocapitalizationType = .words
        nameField.returnKeyType = .done
        nameField.delegate = self
        nameField.layer.cornerRadius = 6
        nameField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 1))
        nameField.leftViewMode = .always
        nameField.accessibilityIdentifier = "eq.editor.name"
        contentView.addSubview(nameField)

        let textLabel = label("PROFILE TEXT", font: DesignSystem.font(8, weight: .semibold), colour: DesignSystem.secondaryText)
        contentView.addSubview(textLabel)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = DesignSystem.font(10)
        textView.textColor = DesignSystem.primaryText
        textView.backgroundColor = DesignSystem.controlFill
        textView.layer.cornerRadius = 6
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 6, bottom: 8, right: 6)
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.delegate = self
        textView.accessibilityIdentifier = "eq.editor.text"
        contentView.addSubview(textView)

        style(actionButton: pasteButton, title: "Paste from Clipboard")
        pasteButton.addTarget(self, action: #selector(pasteTapped), for: .touchUpInside)
        contentView.addSubview(pasteButton)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.font = DesignSystem.font(10)
        hintLabel.textColor = DesignSystem.secondaryText
        hintLabel.numberOfLines = 0
        hintLabel.text = "Accepts Equalizer APO / AutoEQ text: a Preamp line and Filter lines using PK, LSC, HSC, LS or HS. Lines using other filters are kept and listed as skipped."
        contentView.addSubview(hintLabel)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: view.widthAnchor),

            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            nameField.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            nameField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -14),
            nameField.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 6),
            nameField.heightAnchor.constraint(equalToConstant: 38),

            textLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            textLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 18),
            textView.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            textView.topAnchor.constraint(equalTo: textLabel.bottomAnchor, constant: 6),
            textView.heightAnchor.constraint(equalToConstant: 250),

            pasteButton.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            pasteButton.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: 10),

            hintLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            hintLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            hintLabel.topAnchor.constraint(equalTo: pasteButton.bottomAnchor, constant: 12),
            hintLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -30)
        ])
    }

    // MARK: - Actions

    @objc private func cancelTapped() {
        view.endEditing(true)
        dismiss(animated: true)
    }

    @objc private func pasteTapped() {
        guard let pasted = UIPasteboard.general.string, !pasted.isEmpty else { return }
        textView.text = pasted
        view.endEditing(true)
        updateSaveButton()
    }

    @objc private func saveTapped() {
        let text = textView.text ?? ""
        let result: EQParseResult
        do {
            result = try EQProfileParser.parse(text)
        } catch {
            presentError(error)
            return
        }

        let trimmedName = (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = EQProfile(
            id: UUID().uuidString,
            name: trimmedName.isEmpty ? "Untitled profile" : trimmedName,
            preamp: result.preamp,
            filters: result.filters,
            skippedLines: result.skippedLines,
            sourceText: text,
            isEnabled: true
        )
        onSave?(profile)
        view.endEditing(true)
        dismiss(animated: true)
    }

    private func presentError(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let alert = UIAlertController(title: "Could Not Load Profile", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Delegates

    func textViewDidChange(_ textView: UITextView) {
        updateSaveButton()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    private func updateSaveButton() {
        let hasText = !(textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        navigationItem.rightBarButtonItem?.isEnabled = hasText
    }

    // MARK: - Styling

    private func label(_ text: String, font: UIFont, colour: UIColor) -> UILabel {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = text
        label.font = font
        label.textColor = colour
        return label
    }

    private func style(actionButton: UIButton, title: String) {
        actionButton.setTitle(title, for: .normal)
        actionButton.setTitleColor(DesignSystem.accent, for: .normal)
        actionButton.titleLabel?.font = DesignSystem.font(10, weight: .semibold)
        actionButton.backgroundColor = DesignSystem.actionFill
        actionButton.layer.cornerRadius = 6
        actionButton.contentEdgeInsets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
    }
}
