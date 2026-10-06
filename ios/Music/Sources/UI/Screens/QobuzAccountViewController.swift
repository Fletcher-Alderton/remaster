import UIKit
import SafariServices

final class QobuzAccountViewController: UIViewController {
    private let accountStore = QobuzCredentialStore.shared
    private let status = UILabel()
    private let action = UIButton(type: .system)
    private var authSession: SFAuthenticationSession?
    var onAccountChanged: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.pageBackground
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Qobuz Account"
        title.font = DesignSystem.font(23, weight: .bold)
        title.textColor = DesignSystem.primaryText
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = DesignSystem.font(13)
        status.textColor = DesignSystem.secondaryText
        status.numberOfLines = 0
        status.textAlignment = .center
        action.translatesAutoresizingMaskIntoConstraints = false
        action.titleLabel?.font = DesignSystem.font(14, weight: .semibold)
        action.addTarget(self, action: #selector(actionTapped), for: .touchUpInside)
        view.addSubview(title)
        view.addSubview(status)
        view.addSubview(action)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            title.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 36),
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            action.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            action.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 24),
            action.heightAnchor.constraint(equalToConstant: 46),
            action.widthAnchor.constraint(equalToConstant: 210)
        ])
        refresh()
    }

    private func refresh() {
        if accountStore.load() != nil {
            status.text = accountStore.isSessionOnly
                ? "Signed in for this simulator session only. Credentials are held in memory until the app closes."
                : "Signed in. Credentials are stored securely in Keychain."
            action.setTitle("Sign Out", for: .normal)
        } else {
            status.text = "Sign in with your Qobuz account to browse the catalog and stream music."
            action.setTitle("Continue with Qobuz", for: .normal)
        }
        action.backgroundColor = DesignSystem.actionFill
        action.layer.cornerRadius = 9
    }

    @objc private func actionTapped() {
        if accountStore.load() != nil {
            accountStore.delete()
            onAccountChanged?()
            refresh()
            return
        }
        status.text = "Finding Qobuz sign-in…"
        URLSession.shared.dataTask(with: URL(string: "https://play.qobuz.com/login")!) { [weak self] data, _, error in
            if let error = error { DispatchQueue.main.async { self?.showError(error) }; return }
            guard let data = data, let html = String(data: data, encoding: .utf8),
                  let bundlePath = QobuzStreamingClient.firstCapture(
                    pattern: #"<script src=\"(/resources/\d+\.\d+\.\d+-[a-z0-9]\d{3}/bundle\.js)\"></script>"#,
                    in: html
                  ) else {
                DispatchQueue.main.async { self?.showError(QobuzStreamingError.appIDNotFound) }
                return
            }
            let bundleURL = URL(string: "https://play.qobuz.com" + bundlePath)!
            URLSession.shared.dataTask(with: bundleURL) { bundleData, _, bundleError in
                if let bundleError = bundleError { DispatchQueue.main.async { self?.showError(bundleError) }; return }
                guard let bundleData = bundleData, let script = String(data: bundleData, encoding: .utf8),
                      let appID = QobuzStreamingClient.firstCapture(
                        pattern: #"production:\\{api:\\{appId:\"(\\d{9})\",appSecret:\"\\w{32}\""#,
                        in: script
                      ),
                      let url = QobuzStreamingClient.authorizationURL(appID: appID) else {
                    DispatchQueue.main.async { self?.showError(QobuzStreamingError.appIDNotFound) }
                    return
                }
                DispatchQueue.main.async { self?.beginOAuth(url: url, appID: appID) }
            }.resume()
        }.resume()
    }

    private func beginOAuth(url: URL, appID: String) {
        status.text = "Complete sign-in in the browser…"
        authSession = SFAuthenticationSession(url: url, callbackURLScheme: "qobuz-music") { [weak self] callbackURL, error in
            guard let self = self else { return }
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
                    guard let self = self else { return }
                    switch result {
                    case .failure(let error): self.showError(error)
                    case .success(let credentials):
                        do {
                            try self.accountStore.save(credentials)
                            self.refresh()
                            self.onAccountChanged?()
                        } catch { self.showError(error) }
                    }
                }
            }
        }
        authSession?.start()
    }

    private func showError(_ error: Error) {
        status.text = error.localizedDescription
        status.textColor = .systemRed
    }
}
