import UIKit
import SafariServices

final class QobuzAccountViewController: UIViewController {
    private let accountStore = QobuzCredentialStore.shared
    private let status = UILabel()
    private let action = UIButton(type: .system)
    private let retryButton = UIButton(type: .system)
    private let websiteButton = UIButton(type: .system)
    private var accountRequestID = UUID()
    private let closeButton = UIButton(type: .system)
    private var isClosing = false
    private var authSession: SFAuthenticationSession?
    private var hasStartedAutomaticSignIn = false
    var startsSignInAutomatically = false
    var onAccountChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "qobuz.account"
        view.backgroundColor = DesignSystem.pageBackground
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setTitle("Done", for: .normal)
        closeButton.titleLabel?.font = DesignSystem.font(14, weight: .semibold)
        closeButton.accessibilityIdentifier = "qobuz.account.close"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Qobuz Account"
        title.numberOfLines = 0
        title.textAlignment = .center
        title.font = DesignSystem.font(23, weight: .bold)
        title.textColor = DesignSystem.primaryText
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = DesignSystem.font(13)
        status.textColor = DesignSystem.secondaryText
        status.numberOfLines = 0
        status.textAlignment = .center
        action.accessibilityIdentifier = "qobuz.account.action"
        status.accessibilityIdentifier = "qobuz.account.status"
        action.translatesAutoresizingMaskIntoConstraints = false
        action.titleLabel?.font = DesignSystem.font(14, weight: .semibold)
        action.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        view.addSubview(title)
        view.addSubview(status)
        view.addSubview(action)
        NSLayoutConstraint.activate([
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            closeButton.heightAnchor.constraint(equalToConstant: 44),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 60),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            action.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            action.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 24),
            action.heightAnchor.constraint(equalToConstant: 46),
            action.widthAnchor.constraint(equalToConstant: 210)
        ])
        for button in [retryButton, websiteButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(button)
        }
        retryButton.setTitle("Retry Account Details", for: .normal)
        retryButton.accessibilityIdentifier = "qobuz.account.retry"
        retryButton.addTarget(self, action: #selector(retryAccount), for: .touchUpInside)
        websiteButton.setTitle("Manage on Qobuz Website", for: .normal)
        websiteButton.accessibilityIdentifier = "qobuz.account.website"
        websiteButton.addTarget(self, action: #selector(openWebsite), for: .touchUpInside)
        NSLayoutConstraint.activate([
            retryButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            retryButton.topAnchor.constraint(equalTo: action.bottomAnchor, constant: 8),
            retryButton.heightAnchor.constraint(equalToConstant: 44),
            websiteButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            websiteButton.topAnchor.constraint(equalTo: retryButton.bottomAnchor, constant: 8),
            websiteButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        refresh()
        action.isHidden = false
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard startsSignInAutomatically, !hasStartedAutomaticSignIn, accountStore.load() == nil else { return }
        hasStartedAutomaticSignIn = true
        actionTapped()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true {
            isClosing = true
            accountRequestID = UUID()
            authSession?.cancel()
            authSession = nil
        }
    }

    @objc private func closeTapped() {
        accountRequestID = UUID()
        isClosing = true
        authSession?.cancel()
        authSession = nil
        dismiss(animated: true)
    }

    @objc private func openWebsite() {
        guard accountStore.load() != nil, !isClosing else { return }
        // No automatic navigation or credential/token transfer to the browser.
        present(SFSafariViewController(url: URL(string: "https://www.qobuz.com/account")!), animated: true)
    }

    @objc private func retryAccount() { refresh() }

    private func refresh() {
        accountRequestID = UUID()
        retryButton.isHidden = true
        websiteButton.isHidden = accountStore.load() == nil
        action.isEnabled = true
        status.textColor = DesignSystem.secondaryText
        if accountStore.load() != nil {
            status.text = accountStore.isSessionOnly
                ? "Signed in for this simulator session only. Credentials are held in memory until the app closes."
                : "Signed in to Qobuz. Credentials are stored securely in Keychain. Subscription and playback availability are checked when requesting music."
            action.setTitle("Sign Out", for: .normal)
            loadAccount()
        } else {
            status.text = "Sign in with your Qobuz account to browse the catalog and stream music."
            action.setTitle("Continue with Qobuz", for: .normal)
        }
        action.backgroundColor = DesignSystem.actionFill
        action.layer.cornerRadius = 9
    }

    private func loadAccount() {
        guard let credentials = accountStore.load() else { return }
        let requestID = accountRequestID
        status.text = "Loading Qobuz account details…"
        QobuzStreamingClient(credentials: credentials).account { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.isClosing, self.accountRequestID == requestID else { return }
                guard let current = self.accountStore.load(), current.userID == credentials.userID,
                      current.userAuthToken == credentials.userAuthToken else { self.refresh(); return }
                switch result {
                case .success(let account):
                    self.status.text = account.displaySummary + (self.accountStore.isSessionOnly ? "\nSimulator session only; not persisted." : "")
                case .failure:
                    // Do not display raw server errors that might echo request credentials.
                    self.status.text = "Account details could not be loaded. Your local session is still signed in. Retry, or sign out and sign in again if your session has expired."
                    self.retryButton.isHidden = false
                }
            }
        }
    }

    @objc private func actionTapped() {
        if accountStore.load() != nil {
            accountRequestID = UUID()
            isClosing = true
            accountStore.delete()
            // Don't leave the signed-out account's library/catalog text on the device.
            QobuzCatalogResponseCache.shared.removeAll()
            onAccountChanged?()
            dismiss(animated: true)
            return
        }
        action.isEnabled = false
        status.textColor = DesignSystem.secondaryText
        status.text = "Finding Qobuz sign-in…"
        QobuzStreamingClient.discoverWebPlayerConfiguration { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, !self.isClosing else { return }
                switch result {
                case .failure(let error):
                    self.showError(error)
                case .success(let configuration):
                    guard let url = QobuzStreamingClient.authorizationURL(appID: configuration.appID) else {
                        self.showError(QobuzStreamingError.invalidResponse)
                        return
                    }
                    self.beginOAuth(url: url, appID: configuration.appID)
                }
            }
        }
    }

    private func beginOAuth(url: URL, appID: String) {
        status.text = "Complete sign-in in the browser…"
        authSession = SFAuthenticationSession(url: url, callbackURLScheme: "qobuz-music") { [weak self] callbackURL, error in
            DispatchQueue.main.async {
                guard let self = self, !self.isClosing else { return }
                if let error = error { self.showError(error); return }
                guard let callbackURL = callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let code = components.queryItems?.first(where: { $0.name == "code_autorisation" })?.value else {
                    self.showError(QobuzStreamingError.invalidCallback)
                    return
                }
                self.status.text = "Completing Qobuz sign-in…"
                QobuzStreamingClient.exchangeAuthorizationCode(code, appID: appID) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self = self, !self.isClosing else { return }
                        switch result {
                        case .failure(let error): self.showError(error)
                        case .success(let credentials):
                            do {
                                try self.accountStore.save(credentials)
                                self.refresh()
                                self.onAccountChanged?()
                                self.dismiss(animated: true)
                            } catch { self.showError(error) }
                        }
                    }
                }
            }
        }
        if authSession?.start() != true { showError(QobuzStreamingError.invalidResponse) }
    }

    private func showError(_ error: Error) {
        action.isHidden = false
        action.isEnabled = true
        action.setTitle("Retry Sign In", for: .normal)
        status.text = "Sign-in did not complete. " + error.localizedDescription
        status.textColor = .systemRed
    }
}
