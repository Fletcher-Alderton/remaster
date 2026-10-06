import UIKit

final class QobuzCatalogViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    enum Mode { case discover, search, albums, artists }

    var onTrackSelected: ((ScreenTrack) -> Void)?
    var onAlbumSelected: ((ScreenAlbum) -> Void)?
    var onArtistSelected: ((ScreenProfile) -> Void)?

    private enum Row {
        case heading(String)
        case track(ScreenTrack)
        case album(ScreenAlbum)
        case artist(ScreenProfile)
    }

    private let mode: Mode
    private let client: QobuzStreamingClient
    private let table = UITableView(frame: .zero, style: .plain)
    private let searchBar = UISearchBar()
    private let statusLabel = UILabel()
    private var rows: [Row] = []
    private var requestID = 0

    init(mode: Mode, client: QobuzStreamingClient) {
        self.mode = mode
        self.client = client
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.pageBackground
        view.accessibilityIdentifier = "qobuz.\(mode.accessibilityName)"
        searchBar.delegate = self
        searchBar.placeholder = "Search tracks, albums, artists"
        searchBar.searchBarStyle = .minimal
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = mode == .discover
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = DesignSystem.font(11)
        statusLabel.textColor = DesignSystem.secondaryText
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = DesignSystem.pageBackground
        table.separatorColor = DesignSystem.separator
        table.rowHeight = 76
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.register(UITableViewCell.self, forCellReuseIdentifier: "catalog")
        view.addSubview(searchBar)
        view.addSubview(statusLabel)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            table.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        if mode == .discover || mode == .albums || mode == .artists { loadFeatured() }
        else { statusLabel.text = "Search the Qobuz catalog" }
    }

    private func loadFeatured() {
        requestID += 1
        let currentRequest = requestID
        statusLabel.text = "Loading Qobuz discovery…"
        client.featuredCatalog { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.requestID == currentRequest else { return }
                switch result {
                case .failure(let error): self.showError(error)
                case .success(let featured):
                    let albums = (featured.albums?.items ?? []).map(Self.screenAlbum)
                    let artists = (featured.artists?.items ?? []).map(Self.screenProfile)
                    self.rows = []
                    if self.mode == .albums {
                        self.rows = albums.map(Row.album)
                    } else if self.mode == .artists {
                        self.rows = artists.map(Row.artist)
                    } else {
                        if !albums.isEmpty {
                            self.rows.append(.heading("NEW RELEASES"))
                            self.rows.append(contentsOf: albums.map(Row.album))
                        }
                        if !artists.isEmpty {
                            self.rows.append(.heading("FEATURED ARTISTS"))
                            self.rows.append(contentsOf: artists.map(Row.artist))
                        }
                    }
                    self.statusLabel.text = self.rows.isEmpty ? "No featured Qobuz catalog items are available." : self.mode.discoveryCaption
                    self.table.reloadData()
                    self.loadArtwork()
                }
            }
        }
    }

    private func search(query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { rows = []; table.reloadData(); statusLabel.text = "Search the Qobuz catalog"; return }
        requestID += 1
        let currentRequest = requestID
        statusLabel.text = "Searching Qobuz…"
        client.searchCatalog(query: query) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.requestID == currentRequest else { return }
                switch result {
                case .failure(let error): self.showError(error)
                case .success(let results):
                    self.rows = []
                    let tracks = (results.tracks?.items ?? []).map(Self.screenTrack)
                    let albums = (results.albums?.items ?? []).map(Self.screenAlbum)
                    let artists = (results.artists?.items ?? []).map(Self.screenProfile)
                    if !tracks.isEmpty { self.rows.append(.heading("TRACKS")); self.rows.append(contentsOf: tracks.map(Row.track)) }
                    if !albums.isEmpty { self.rows.append(.heading("ALBUMS")); self.rows.append(contentsOf: albums.map(Row.album)) }
                    if !artists.isEmpty { self.rows.append(.heading("ARTISTS")); self.rows.append(contentsOf: artists.map(Row.artist)) }
                    self.statusLabel.text = self.rows.isEmpty ? "No results for ‘\(query)’" : "Qobuz search results for ‘\(query)’"
                    self.table.reloadData()
                    self.loadArtwork()
                }
            }
        }
    }

    private func showError(_ error: Error) {
        rows = []
        table.reloadData()
        statusLabel.text = error.localizedDescription
    }

    private func loadArtwork() {
        for row in rows {
            let url: URL?
            switch row {
            case .heading: continue
            case .track(let track): url = track.artworkURL
            case .album(let album): url = album.artworkURL
            case .artist(let artist): url = artist.artworkURL
            }
            guard let url = url else { continue }
            ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: 128) { [weak self] image in
                guard image != nil else { return }
                self?.table.reloadData()
            }
        }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        search(query: searchBar.text ?? "")
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        guard searchText.isEmpty else { return }
        requestID += 1
        rows = []
        table.reloadData()
        statusLabel.text = "Search the Qobuz catalog"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "catalog", for: indexPath)
        guard rows.indices.contains(indexPath.row) else { return cell }
        cell.imageView?.image = nil
        cell.textLabel?.numberOfLines = 2
        cell.detailTextLabel?.text = nil
        cell.accessoryType = .none
        switch rows[indexPath.row] {
        case .heading(let title):
            cell.textLabel?.text = title
            cell.textLabel?.font = DesignSystem.font(10, weight: .bold)
            cell.textLabel?.textColor = DesignSystem.accent
            cell.backgroundColor = DesignSystem.controlFill
        case .track(let track):
            configure(cell, title: track.title, subtitle: "\(track.artist) · \(track.album)", artworkURL: track.artworkURL)
        case .album(let album):
            configure(cell, title: album.title, subtitle: "\(album.artist) · \(album.year)", artworkURL: album.artworkURL)
        case .artist(let artist):
            configure(cell, title: artist.name, subtitle: artist.subtitle, artworkURL: artist.artworkURL, rounded: true)
        }
        cell.accessibilityIdentifier = "qobuz.catalogRow.\(indexPath.row)"
        return cell
    }

    private func configure(_ cell: UITableViewCell, title: String, subtitle: String, artworkURL: URL?, rounded: Bool = false) {
        cell.textLabel?.text = title
        cell.textLabel?.font = DesignSystem.font(13, weight: .semibold)
        cell.textLabel?.textColor = DesignSystem.primaryText
        cell.detailTextLabel?.text = subtitle
        cell.backgroundColor = DesignSystem.pageBackground
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.image = artworkURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: "remote|\($0.absoluteString)|128") }
        cell.imageView?.layer.cornerRadius = rounded ? 23 : 5
        cell.imageView?.clipsToBounds = true
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        switch rows[indexPath.row] {
        case .track(let track): onTrackSelected?(track)
        case .album(let album): onAlbumSelected?(album)
        case .artist(let artist): onArtistSelected?(artist)
        case .heading: break
        }
    }

    private static func screenTrack(_ source: QobuzSearchTrack) -> ScreenTrack {
        let mapped = QobuzCatalogMapper.track(source)
        let artwork = source.album?.imageURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: $0.absoluteString) }
        return ScreenTrack(id: mapped.id, title: mapped.title, artist: mapped.artist, album: mapped.album, quality: mapped.quality, artwork: artwork, artworkURL: mapped.artworkURL, catalogAlbumID: mapped.catalogAlbumID, catalogArtistID: mapped.catalogArtistID, duration: mapped.duration)
    }

    private static func screenAlbum(_ source: QobuzCatalogAlbum) -> ScreenAlbum {
        let mapped = QobuzCatalogMapper.album(source)
        let artwork = source.artworkURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: $0.absoluteString) }
        let tracks = mapped.tracks.map { track in
            ScreenTrack(id: track.id, title: track.title, artist: track.artist, album: track.album, quality: track.quality, artwork: artwork, artworkURL: track.artworkURL, catalogAlbumID: track.catalogAlbumID, catalogArtistID: track.catalogArtistID, duration: track.duration)
        }
        return ScreenAlbum(id: mapped.id, title: mapped.title, artist: mapped.artist, year: mapped.year, genre: mapped.genre, quality: mapped.quality, artwork: artwork, artworkURL: mapped.artworkURL, tracks: tracks)
    }

    private static func screenProfile(_ source: QobuzCatalogArtist) -> ScreenProfile {
        let mapped = QobuzCatalogMapper.profile(source)
        let artwork = source.artworkURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: $0.absoluteString) }
        return ScreenProfile(id: mapped.id, name: mapped.name, subtitle: mapped.subtitle, information: mapped.information, artwork: artwork, artworkURL: mapped.artworkURL, albums: mapped.albums)
    }
}

private extension QobuzCatalogViewController.Mode {
    var accessibilityName: String {
        switch self { case .discover: return "discover"; case .search: return "search"; case .albums: return "albums"; case .artists: return "artists" }
    }

    var discoveryCaption: String {
        switch self { case .discover: return "Discover new releases and artists on Qobuz"; case .albums: return "Featured Qobuz albums"; case .artists: return "Featured Qobuz artists"; case .search: return "Search the Qobuz catalog" }
    }
}

