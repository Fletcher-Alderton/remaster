import AVFoundation
import SafariServices
import UIKit

/// Standalone live-stream spike, intentionally separate from the local-file queue.
final class QobuzStreamTestViewController: UIViewController, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate {
    private let credentialsStore = QobuzCredentialStore()
    private var authSession: SFAuthenticationSession?
    private var player: AVPlayer?
    private var itemObservation: NSKeyValueObservation?
    private var timeObserver: Any?

    private let accountButton = UIButton(type: .system)
    private let trackIDField = UITextField()
    private let searchField = UITextField()
    private let searchButton = UIButton(type: .system)
    private let resultsTable = UITableView(frame: .zero, style: .plain)
    private let qualityControl = UISegmentedControl(items: ["MP3", "CD", "96 kHz", "192 kHz"])
    private let qualityDetailLabel = UILabel()
    private let statusLabel = UILabel()
    private let resolveButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let seekSlider = UISlider()
    private let timeLabel = UILabel()
    private var isResolving = false
    private var searchResults: [QobuzSearchTrack] = []
    private var selectedQuality: QobuzStreamQuality = .mp3

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.settingsBackground
        buildView()
        updateAccountButton()
    }

    deinit {
        itemObservation?.invalidate()
        if let timeObserver = timeObserver { player?.removeTimeObserver(timeObserver) }
        player?.pause()
    }

    private func buildView() {
        let doneButton = UIButton(type: .system)
        doneButton.setTitle("Done", for: .normal)
        doneButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(doneButton)

        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)
        let contentView = UIView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(contentView)

        let title = UILabel()
        title.text = "Qobuz Streaming Spike"
        title.font = DesignSystem.font(19, weight: .bold)
        title.textColor = DesignSystem.primaryText
        title.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(title)

        let explanation = UILabel()
        explanation.text = "Search Qobuz songs, choose a stream quality, then play. A paid subscription is required."
        explanation.font = DesignSystem.font(11)
        explanation.textColor = DesignSystem.secondaryText
        explanation.numberOfLines = 0
        explanation.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(explanation)

        accountButton.addTarget(self, action: #selector(accountTapped), for: .touchUpInside)
        accountButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(accountButton)

        searchField.placeholder = "Search songs or artists"
        searchField.font = DesignSystem.font(12)
        searchField.textColor = DesignSystem.primaryText
        searchField.backgroundColor = DesignSystem.pageBackground
        searchField.layer.cornerRadius = 7
        searchField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 9, height: 1))
        searchField.leftViewMode = .always
        searchField.returnKeyType = .search
        searchField.delegate = self
        searchField.accessibilityIdentifier = "qobuz.search"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchField)

        searchButton.setTitle("Search", for: .normal)
        searchButton.titleLabel?.font = DesignSystem.font(12, weight: .semibold)
        searchButton.addTarget(self, action: #selector(searchTapped), for: .touchUpInside)
        searchButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchButton)

        resultsTable.dataSource = self
        resultsTable.delegate = self
        resultsTable.rowHeight = 48
        resultsTable.isScrollEnabled = true
        resultsTable.backgroundColor = DesignSystem.pageBackground
        resultsTable.layer.cornerRadius = 7
        resultsTable.accessibilityIdentifier = "qobuz.searchResults"
        resultsTable.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(resultsTable)

        let qualityLabel = UILabel()
        qualityLabel.text = "Audio quality"
        qualityLabel.font = DesignSystem.font(11, weight: .semibold)
        qualityLabel.textColor = DesignSystem.primaryText
        qualityLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(qualityLabel)

        qualityControl.selectedSegmentIndex = 0
        qualityControl.addTarget(self, action: #selector(qualityChanged), for: .valueChanged)
        qualityControl.accessibilityIdentifier = "qobuz.quality"
        qualityControl.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(qualityControl)

        qualityDetailLabel.text = selectedQuality.detail
        qualityDetailLabel.font = DesignSystem.font(10)
        qualityDetailLabel.textColor = DesignSystem.secondaryText
        qualityDetailLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(qualityDetailLabel)

        trackIDField.placeholder = "Or enter a Qobuz track ID"
        trackIDField.keyboardType = .numberPad
        trackIDField.font = DesignSystem.font(12)
        trackIDField.textColor = DesignSystem.primaryText
        trackIDField.backgroundColor = DesignSystem.pageBackground
        trackIDField.layer.cornerRadius = 7
        trackIDField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 9, height: 1))
        trackIDField.leftViewMode = .always
        trackIDField.delegate = self
        trackIDField.accessibilityIdentifier = "qobuz.trackID"
        trackIDField.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(trackIDField)

        resolveButton.setTitle("Resolve & Play", for: .normal)
        resolveButton.titleLabel?.font = DesignSystem.font(12, weight: .semibold)
        resolveButton.addTarget(self, action: #selector(resolveTapped), for: .touchUpInside)
        resolveButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(resolveButton)

        playButton.setTitle("Pause", for: .normal)
        playButton.addTarget(self, action: #selector(togglePlayback), for: .touchUpInside)
        playButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playButton)

        seekSlider.addTarget(self, action: #selector(seekChanged), for: .valueChanged)
        seekSlider.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(seekSlider)

        timeLabel.text = "0:00 / 0:00"
        timeLabel.font = DesignSystem.font(10)
        timeLabel.textColor = DesignSystem.secondaryText
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(timeLabel)

        statusLabel.text = "Sign in, search for a song, or enter a track ID."
        statusLabel.font = DesignSystem.font(10)
        statusLabel.textColor = DesignSystem.secondaryText
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            doneButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 52),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            title.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            title.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -18),
            title.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            explanation.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            explanation.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            explanation.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            accountButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            accountButton.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: searchButton.leadingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: accountButton.bottomAnchor, constant: 8),
            searchField.heightAnchor.constraint(equalToConstant: 40),
            searchButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            searchButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            resultsTable.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            resultsTable.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor),
            resultsTable.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            resultsTable.heightAnchor.constraint(equalToConstant: 192),
            qualityLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            qualityLabel.topAnchor.constraint(equalTo: resultsTable.bottomAnchor, constant: 10),
            qualityControl.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            qualityControl.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor),
            qualityControl.topAnchor.constraint(equalTo: qualityLabel.bottomAnchor, constant: 5),
            qualityDetailLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            qualityDetailLabel.topAnchor.constraint(equalTo: qualityControl.bottomAnchor, constant: 4),
            trackIDField.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            trackIDField.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor),
            trackIDField.topAnchor.constraint(equalTo: qualityDetailLabel.bottomAnchor, constant: 8),
            trackIDField.heightAnchor.constraint(equalToConstant: 40),
            resolveButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            resolveButton.topAnchor.constraint(equalTo: trackIDField.bottomAnchor, constant: 5),
            playButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            playButton.topAnchor.constraint(equalTo: resolveButton.bottomAnchor, constant: 8),
            seekSlider.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            seekSlider.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor),
            seekSlider.topAnchor.constraint(equalTo: playButton.bottomAnchor, constant: 2),
            timeLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            timeLabel.topAnchor.constraint(equalTo: seekSlider.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: searchButton.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: timeLabel.bottomAnchor, constant: 8),
            statusLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])
    }


    private func updateAccountButton() {
        accountButton.setTitle(credentialsStore.load() == nil ? "Sign In to Qobuz" : "Sign Out of Qobuz", for: .normal)
    }

    @objc private func accountTapped() {
        if credentialsStore.load() != nil {
            credentialsStore.delete()
            updateAccountButton()
            statusLabel.text = "Signed out of Qobuz."
            return
        }
        statusLabel.text = "Finding Qobuz sign-in…"
        URLSession.shared.dataTask(with: URL(string: "https://play.qobuz.com/login")!) { [weak self] data, _, error in
            if let error = error { DispatchQueue.main.async { self?.showError(error) }; return }
            guard let data = data, let html = String(data: data, encoding: .utf8),
                  let bundlePath = QobuzStreamingClient.firstCapture(
                    pattern: #"<script src="(/resources/\d+\.\d+\.\d+-[a-z0-9]\d{3}/bundle\.js)"></script>"#,
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
                        pattern: #"production:\{api:\{appId:"(\d{9})",appSecret:"\w{32}""#,
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
        statusLabel.text = "Complete sign-in in the browser…"
        authSession = SFAuthenticationSession(url: url, callbackURLScheme: "qobuz-music") { [weak self] callbackURL, error in
            guard let self = self else { return }
            if let error = error { self.showError(error); return }
            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code_autorisation" })?.value else {
                self.showError(QobuzStreamingError.invalidCallback)
                return
            }
            self.statusLabel.text = "Completing Qobuz sign-in…"
            QobuzStreamingClient.exchangeAuthorizationCode(code, appID: appID) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .failure(let error): self.showError(error)
                    case .success(let credentials):
                        do {
                            try self.credentialsStore.save(credentials)
                            self.updateAccountButton()
                            self.statusLabel.text = self.credentialsStore.isSessionOnly
                                ? "Signed in for this simulator session only. Sign-in will be lost when the app closes."
                                : "Signed in. Credentials are stored securely on this device."
                        } catch { self.showError(error) }
                    }
                }
            }
        }
        authSession?.start()
    }

    @objc private func searchTapped() {
        searchField.resignFirstResponder()
        guard let credentials = credentialsStore.load() else {
            statusLabel.text = "Sign in to Qobuz first."
            return
        }
        guard let query = searchField.text, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            statusLabel.text = QobuzStreamingError.emptySearchQuery.localizedDescription
            return
        }
        searchButton.isEnabled = false
        statusLabel.textColor = DesignSystem.secondaryText
        statusLabel.text = "Searching Qobuz…"
        QobuzStreamingClient(credentials: credentials).searchTracks(query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.searchButton.isEnabled = true
                switch result {
                case .failure(let error): self.showError(error)
                case .success(let tracks):
                    self.searchResults = tracks
                    self.resultsTable.reloadData()
                    self.statusLabel.textColor = DesignSystem.secondaryText
                    self.statusLabel.text = tracks.isEmpty ? "No matching songs found." : "Tap a song to select its track ID."
                }
            }
        }
    }

    @objc private func qualityChanged() {
        let index = max(0, min(qualityControl.selectedSegmentIndex, QobuzStreamQuality.allCases.count - 1))
        selectedQuality = QobuzStreamQuality.allCases[index]
        qualityDetailLabel.text = selectedQuality.detail
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        searchResults.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "QobuzSearchResult"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier) ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        let track = searchResults[indexPath.row]
        cell.textLabel?.text = track.title
        cell.textLabel?.font = DesignSystem.font(11, weight: .semibold)
        cell.textLabel?.textColor = DesignSystem.primaryText
        cell.detailTextLabel?.text = track.subtitle.isEmpty ? "Track ID \(track.id)" : track.subtitle
        cell.detailTextLabel?.font = DesignSystem.font(9)
        cell.detailTextLabel?.textColor = DesignSystem.secondaryText
        cell.backgroundColor = DesignSystem.pageBackground
        cell.accessibilityIdentifier = "qobuz.searchResult.\(track.id)"
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let track = searchResults[indexPath.row]
        trackIDField.text = String(track.id)
        statusLabel.textColor = DesignSystem.secondaryText
        statusLabel.text = "Selected \(track.title) — \(selectedQuality.title). Tap Resolve & Play."
    }

    @objc private func resolveTapped() {
        guard !isResolving else { return }
        trackIDField.resignFirstResponder()
        guard let credentials = credentialsStore.load() else {
            statusLabel.text = "Sign in to Qobuz first."
            return
        }
        guard let text = trackIDField.text, let trackID = Int64(text), trackID > 0 else {
            statusLabel.text = QobuzStreamingError.invalidTrackID.localizedDescription
            return
        }
        isResolving = true
        resolveButton.isEnabled = false
        statusLabel.textColor = DesignSystem.secondaryText
        QobuzStreamingClient(credentials: credentials).requestStreamURL(
            trackID: trackID,
            quality: selectedQuality,
            progress: { [weak self] message in
                DispatchQueue.main.async {
                    guard let self = self, self.isResolving else { return }
                    self.statusLabel.text = message
                }
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isResolving = false
                self.resolveButton.isEnabled = true
                switch result {
                case .failure(let error): self.showError(error)
                case .success(let stream) where stream.formatID != self.selectedQuality.rawValue:
                    self.showError(QobuzStreamingError.api("Qobuz returned format \(stream.formatID), not \(self.selectedQuality.title)."))
                case .success(let stream):
                    self.statusLabel.text = "Starting \(self.selectedQuality.title) stream (\(stream.bitDepth)-bit / \(Int(stream.samplingRate * 1000)) Hz)…"
                    self.startPlayback(url: stream.url)
                }
            }
        }
    }

    private func startPlayback(url: URL) {
        itemObservation?.invalidate()
        if let timeObserver = timeObserver { player?.removeTimeObserver(timeObserver) }
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        let player = AVPlayer(playerItem: item)
        self.player = player
        itemObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                switch observedItem.status {
                case .readyToPlay:
                    do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: []) }
                    catch { self?.showError(error); return }
                    try? AVAudioSession.sharedInstance().setActive(true)
                    player.play()
                    self?.playButton.setTitle("Pause", for: .normal)
                    self?.statusLabel.text = "Playing Qobuz stream. Test seeking and playback stability."
                case .failed:
                    self?.showError(observedItem.error ?? QobuzStreamingError.invalidResponse)
                default: break
                }
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let elapsed = CMTimeGetSeconds(time)
            let duration = CMTimeGetSeconds(item.duration)
            guard elapsed.isFinite, duration.isFinite, duration > 0 else { return }
            self?.seekSlider.value = Float(elapsed / duration)
            self?.timeLabel.text = "\(Self.timeString(elapsed)) / \(Self.timeString(duration))"
        }
    }

    @objc private func togglePlayback() {
        guard let player = player else { return }
        if player.rate == 0 {
            player.play()
            playButton.setTitle("Pause", for: .normal)
        } else {
            player.pause()
            playButton.setTitle("Play", for: .normal)
        }
    }

    @objc private func seekChanged() {
        guard let duration = player?.currentItem?.duration else { return }
        let seconds = CMTimeGetSeconds(duration) * Double(seekSlider.value)
        guard seconds.isFinite else { return }
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    @objc private func closeTapped() { dismiss(animated: true) }

    private func showError(_ error: Error) {
        statusLabel.text = error.localizedDescription
        statusLabel.textColor = .systemRed
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === searchField { searchTapped() }
        return true
    }

    private static func timeString(_ time: Double) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
