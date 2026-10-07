import SafariServices
import UIKit

/// Standalone live-stream spike used to validate Qobuz stream resolution and playback.
final class QobuzStreamTestViewController: UIViewController, UITextFieldDelegate, UITableViewDataSource, UITableViewDelegate {
    var onPlayInApp: ((QobuzSearchTrack, QobuzStreamQuality) -> Void)?
    private let credentialsStore = QobuzCredentialStore.shared
    private let streamPlayer = QobuzStreamPlayer()
    private var authSession: SFAuthenticationSession?
    private var playbackStatusMessage: String?
    private let cacheLock = NSLock()
    private let accountButton = UIButton(type: .system)
    private let trackIDField = UITextField()
    private let searchField = UITextField()
    private let searchButton = UIButton(type: .system)
    private let resultsTable = UITableView(frame: .zero, style: .plain)
    private let qualityControl = UISegmentedControl(items: ["MP3", "CD", "96 kHz", "192 kHz"])
    private let qualityDetailLabel = UILabel()
    private let statusLabel = UILabel()
    private let playerButton = UIButton(type: .system)
    private let playInAppButton = UIButton(type: .system)
    private let playButton = UIButton(type: .system)
    private let seekSlider = UISlider()
    private let timeLabel = UILabel()
    private var isResolving = false
    private var searchResults: [QobuzSearchTrack] = []
    private var selectedQuality: QobuzStreamQuality = .mp3
    private var selectedSearchTrack: QobuzSearchTrack?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.settingsBackground
        buildView()
        updateAccountButton()
        streamPlayer.onStatusChange = { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch status {
                case .playing:
                    self.playButton.setTitle("Pause", for: .normal)
                    self.statusLabel.text = self.playbackStatusMessage ?? "Playing Qobuz stream. Test seeking and playback stability."
                case .paused:
                    self.playButton.setTitle("Play", for: .normal)
                case .failed(let error):
                    self.showError(error)
                }
            }
        }
        streamPlayer.onTimeChange = { [weak self] elapsed, duration in
            self?.seekSlider.value = Float(elapsed / duration)
            self?.timeLabel.text = "\(Self.timeString(elapsed)) / \(Self.timeString(duration))"
        }
    }

    deinit {
        streamPlayer.stop()
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

        playInAppButton.setTitle("Play in App", for: .normal)
        playInAppButton.titleLabel?.font = DesignSystem.font(12, weight: .semibold)
        playInAppButton.addTarget(self, action: #selector(playInAppTapped), for: .touchUpInside)
        playInAppButton.accessibilityIdentifier = "qobuz.playInApp"
        playInAppButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playInAppButton)

        playerButton.setTitle("Resolve & Play Test", for: .normal)
        playerButton.titleLabel?.font = DesignSystem.font(12, weight: .semibold)
        playerButton.addTarget(self, action: #selector(resolveTapped), for: .touchUpInside)
        playerButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(playerButton)

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
            playerButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            playerButton.topAnchor.constraint(equalTo: trackIDField.bottomAnchor, constant: 5),
            playInAppButton.leadingAnchor.constraint(equalTo: playerButton.trailingAnchor, constant: 12),
            playInAppButton.centerYAnchor.constraint(equalTo: playerButton.centerYAnchor),
            playButton.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            playButton.topAnchor.constraint(equalTo: playerButton.bottomAnchor, constant: 8),
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
        QobuzStreamingClient.discoverWebPlayerConfiguration { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
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
                    self.loadArtwork(for: tracks)
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
        if let imageURL = track.album?.imageURL,
           let image = ArtworkImagePipeline.shared.cachedImage(for: imageURL.absoluteString) {
            cell.imageView?.image = image
        } else {
            cell.imageView?.image = nil
        }
        cell.accessibilityIdentifier = "qobuz.searchResult.\(track.id)"
        cell.accessoryType = .disclosureIndicator
        if let imageURL = track.album?.imageURL {
            ArtworkImagePipeline.shared.image(forRemoteURL: imageURL, maximumPixelSize: 80) { [weak tableView, weak cell] image in
                guard let tableView = tableView, let cell = cell,
                      tableView.indexPath(for: cell) == indexPath else { return }
                cell.imageView?.image = image
                cell.setNeedsLayout()
            }
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let track = searchResults[indexPath.row]
        selectedSearchTrack = track
        trackIDField.text = String(track.id)
        statusLabel.textColor = DesignSystem.secondaryText
        statusLabel.text = "Selected \(track.title) — \(selectedQuality.title). Tap Play here, or Play in App."
    }

    private func loadArtwork(for tracks: [QobuzSearchTrack]) {
        let artworkURLs = Set(tracks.compactMap { $0.album?.imageURL })
        for url in artworkURLs {
            ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: 320) { [weak self] image in
                guard let self = self, let image = image else { return }
                self.cacheLock.lock()
                let stillRelevant = self.selectedSearchTrack?.album?.imageURL == url
                self.cacheLock.unlock()
                self.refreshVisibleSearchArtwork(url: url, image: image)
                if stillRelevant {
                    self.refreshSelectedTrackArtwork(image, url: url)
                }
            }
        }
    }

    private func refreshSelectedTrackArtwork(_ image: UIImage, url: URL) {
        cacheLock.lock()
        let selected = selectedSearchTrack
        cacheLock.unlock()
        guard selected?.album?.imageURL == url else { return }
        ArtworkImagePipeline.shared.cache(image, for: url.absoluteString)
    }

    private func refreshVisibleSearchArtwork(url: URL, image: UIImage) {
        for indexPath in resultsTable.indexPathsForVisibleRows ?? [] {
            guard searchResults.indices.contains(indexPath.row),
                  searchResults[indexPath.row].album?.imageURL == url,
                  let cell = resultsTable.cellForRow(at: indexPath) else { continue }
            cell.imageView?.image = image
            cell.setNeedsLayout()
        }
    }

    @objc private func playInAppTapped() {
        guard let track = selectedSearchTrack else {
            statusLabel.textColor = .systemRed
            statusLabel.text = "Search for and select a Qobuz track first."
            return
        }
        onPlayInApp?(track, selectedQuality)
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
        playerButton.isEnabled = false
        playbackStatusMessage = nil
        let requestedQuality = selectedQuality
        statusLabel.textColor = DesignSystem.secondaryText
        QobuzStreamingClient(credentials: credentials).requestStreamURL(
            trackID: trackID,
            quality: requestedQuality,
            progress: { [weak self] message in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard self.isResolving else { return }
                    self.statusLabel.text = message
                }
            }
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isResolving = false
                self.playerButton.isEnabled = true
                switch result {
                case .failure(let error): self.showError(error)
                case .success(let stream):
                    guard let actualQuality = Self.quality(forFormatID: stream.formatID) else {
                        self.showError(QobuzStreamingError.api("Qobuz returned an unknown stream format ID (\(stream.formatID)); playback was not started."))
                        return
                    }
                    let actualRateHz = Int(stream.samplingRate * 1000)
                    let formatDescription = "Actual stream: \(actualQuality.title) (format \(stream.formatID)), \(stream.bitDepth)-bit / \(actualRateHz) Hz."
                    if actualQuality != requestedQuality {
                        if actualQuality.rawValue < requestedQuality.rawValue {
                            self.playbackStatusMessage = "Downgrade: requested \(requestedQuality.title), but Qobuz provided \(actualQuality.title). Playing the returned stream. \(formatDescription)"
                        } else {
                            self.playbackStatusMessage = "Requested \(requestedQuality.title), but Qobuz provided \(actualQuality.title). Playing the returned stream. \(formatDescription)"
                        }
                    } else {
                        self.playbackStatusMessage = "Playing requested \(requestedQuality.title). \(formatDescription)"
                    }
                    self.statusLabel.text = self.playbackStatusMessage
                    self.startPlayback(url: stream.url)
                }
            }
        }
    }

    private func startPlayback(url: URL) {
        streamPlayer.play(url: url)
    }

    @objc private func togglePlayback() {
        streamPlayer.togglePlayback()
    }

    @objc private func seekChanged() {
        streamPlayer.seek(to: seekSlider.value)
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

    private static func quality(forFormatID formatID: Int) -> QobuzStreamQuality? {
        switch formatID {
        case QobuzStreamQuality.mp3.rawValue: return .mp3
        case QobuzStreamQuality.cd.rawValue: return .cd
        case QobuzStreamQuality.hiRes96.rawValue: return .hiRes96
        case QobuzStreamQuality.hiRes192.rawValue: return .hiRes192
        default: return nil
        }
    }

    private static func timeString(_ time: Double) -> String {
        let seconds = max(0, Int(time))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
