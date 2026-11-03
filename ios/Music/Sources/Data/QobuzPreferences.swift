import Foundation
import UIKit

enum QobuzPreferences {
    private static let qualityKey = "Music.Qobuz.streamQuality"

    static var requestedQualityGuidance: String {
        "Requested quality: \(quality.detail). Applies to the next stream. Availability depends on the track and your subscription. Actual output depends on your device and audio route; this does not guarantee bit-perfect playback."
    }

    static var quality: QobuzStreamQuality {
        get { QobuzStreamQuality(rawValue: UserDefaults.standard.integer(forKey: qualityKey)) ?? .cd }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: qualityKey) }
    }
}

final class QobuzWelcomeViewController: UIViewController {
    private let onSignIn: () -> Void

    init(onSignIn: @escaping () -> Void) {
        self.onSignIn = onSignIn
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.pageBackground
        let title = UILabel()
        title.translatesAutoresizingMaskIntoConstraints = false
        title.text = "Qobuz"
        title.font = DesignSystem.font(30, weight: .bold)
        title.textColor = DesignSystem.primaryText
        let subtitle = UILabel()
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.text = "Discover and stream high-resolution music. Sign in to your Qobuz account to get started."
        subtitle.font = DesignSystem.font(14)
        subtitle.textColor = DesignSystem.secondaryText
        subtitle.textAlignment = .center
        subtitle.numberOfLines = 0
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle("Continue with Qobuz", for: .normal)
        button.titleLabel?.font = DesignSystem.font(15, weight: .semibold)
        button.backgroundColor = DesignSystem.actionFill
        button.layer.cornerRadius = 10
        button.addTarget(self, action: #selector(signIn), for: .touchUpInside)
        [title, subtitle, button].forEach(view.addSubview)
        NSLayoutConstraint.activate([
            title.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            title.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -88),
            subtitle.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 30),
            subtitle.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -30),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 16),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 24),
            button.heightAnchor.constraint(equalToConstant: 48),
            button.widthAnchor.constraint(equalToConstant: 220)
        ])
    }

    @objc private func signIn() { onSignIn() }
}
