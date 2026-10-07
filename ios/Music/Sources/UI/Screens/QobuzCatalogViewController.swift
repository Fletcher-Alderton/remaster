import UIKit

private final class QobuzCatalogCell: UITableViewCell {
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: .subtitle, reuseIdentifier: reuseIdentifier)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class QobuzCatalogViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    enum Mode { case discover, search, albums, artists, tracks }

    var onTrackSelected: ((ScreenTrack) -> Void)?
    var onAlbumSelected: ((ScreenAlbum) -> Void)?
    var onArtistSelected: ((ScreenProfile) -> Void)?
    var onPlaylistSelected: ((QobuzCatalogPlaylist) -> Void)?

    private enum Row {
        case heading(String)
        case track(ScreenTrack)
        case album(ScreenAlbum)
        case artist(ScreenProfile)
        case playlist(QobuzCatalogPlaylist)
        case loadMorePlaylists
    }

    private let mode: Mode
    private let client: QobuzStreamingClient
    private let table = UITableView(frame: .zero, style: .plain)
    private let searchBar = UISearchBar()
    private let statusLabel = UILabel()
    private let libraryRefreshControl = UIRefreshControl()
    private let genreScroll = UIScrollView()
    private let genreStack = UIStackView()
    private let tagScroll = UIScrollView()
    private let tagStack = UIStackView()
    private var genreHeightConstraint: NSLayoutConstraint!
    private var tagHeightConstraint: NSLayoutConstraint!
    private var rows: [Row] = []
    private var requestID = 0
    private var libraryRows: [Row] = []
    private var didLoadLibrary = false
    private var isLoadingLibrary = false
    private var libraryError: String?
    private var discoveryGeneration = 0
    private var playlistDetailRequestID = 0
    private var genres: [QobuzCatalogGenre] = []
    private var discoveryResponse: QobuzCatalogDiscoveryResponse?
    private var selectedGenreID: String?
    private var selectedPlaylistTag: String?
    private var fetchedPlaylists: [QobuzCatalogPlaylist]?
    private var playlistTotal: Int?
    private var nextPlaylistOffset = 0
    private var isLoadingPlaylists = false
    private var hasMorePlaylists = false
    private var didRequestGenres = false

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
        searchBar.placeholder = mode.isLibrary ? "Search saved \(mode.accessibilityName)" : "Search tracks, albums, artists"
        searchBar.accessibilityIdentifier = "qobuz.\(mode.accessibilityName).search"
        searchBar.searchBarStyle = .minimal
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        searchBar.isHidden = mode == .discover
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = DesignSystem.font(11)
        statusLabel.textColor = DesignSystem.secondaryText
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 0
        statusLabel.accessibilityIdentifier = "qobuz.\(mode.accessibilityName).status"
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = DesignSystem.pageBackground
        table.separatorColor = DesignSystem.separator
        table.rowHeight = 76
        table.dataSource = self
        table.delegate = self
        table.keyboardDismissMode = .onDrag
        table.estimatedRowHeight = 72
        table.register(QobuzCatalogCell.self, forCellReuseIdentifier: "catalog")
        if mode.isLibrary {
            table.alwaysBounceVertical = true
            table.contentInset.bottom = 90
            table.scrollIndicatorInsets.bottom = 90
            libraryRefreshControl.tintColor = DesignSystem.accent
            libraryRefreshControl.accessibilityLabel = "Refresh Qobuz library"
            libraryRefreshControl.addTarget(self, action: #selector(refreshLibrary), for: .valueChanged)
            table.refreshControl = libraryRefreshControl
        }
        configureFilterScrollView(genreScroll, stack: genreStack)
        configureFilterScrollView(tagScroll, stack: tagStack)
        genreStack.spacing = 8
        tagStack.spacing = 8
        genreHeightConstraint = genreScroll.heightAnchor.constraint(equalToConstant: mode == .discover ? 40 : 0)
        tagHeightConstraint = tagScroll.heightAnchor.constraint(equalToConstant: 0)
        view.addSubview(searchBar)
        view.addSubview(statusLabel)
        view.addSubview(genreScroll)
        view.addSubview(tagScroll)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.heightAnchor.constraint(equalToConstant: mode == .discover ? 0 : 56),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            statusLabel.topAnchor.constraint(equalTo: searchBar.bottomAnchor, constant: 8),
            genreScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            genreScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            genreScroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4),
            genreHeightConstraint,
            tagScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            tagScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            tagScroll.topAnchor.constraint(equalTo: genreScroll.bottomAnchor),
            tagHeightConstraint,
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            table.topAnchor.constraint(equalTo: tagScroll.bottomAnchor, constant: 4),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        if mode == .discover {
            loadDiscovery()
        } else if mode.isLibrary {
            loadLibrary()
        } else {
            statusLabel.text = "Search the Qobuz catalog"
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh cached tabs and library contents after returning from a detail.
        // The in-flight guard also prevents a second request on initial appearance.
        if mode.isLibrary { loadLibrary() }
    }

    @objc private func refreshLibrary() { loadLibrary() }

    private func configureFilterScrollView(_ scrollView: UIScrollView, stack: UIStackView) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.alignment = .center
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    private func filterChip(title: String, selected: Bool, index: Int, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.tag = index
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = DesignSystem.font(11, weight: .semibold)
        button.setTitleColor(selected ? DesignSystem.primaryText : DesignSystem.secondaryText, for: .normal)
        button.backgroundColor = selected ? DesignSystem.actionFill : DesignSystem.controlFill
        button.layer.cornerRadius = 16
        button.layer.borderWidth = 1
        button.layer.borderColor = DesignSystem.separator.cgColor
        button.contentEdgeInsets = UIEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    private func updateGenreFilters() {
        genreStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        genreStack.addArrangedSubview(filterChip(
            title: "All genres",
            selected: selectedGenreID == nil,
            index: 0,
            action: #selector(genreChipTapped(_:))
        ))
        for (index, genre) in genres.enumerated() {
            guard let name = genre.name else { continue }
            genreStack.addArrangedSubview(filterChip(
                title: name,
                selected: genre.id == selectedGenreID,
                index: index + 1,
                action: #selector(genreChipTapped(_:))
            ))
        }
    }

    private func updatePlaylistTagFilters() {
        tagStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let tags = discoveryResponse?.containers?.playlistsTags?.data?.items ?? []
        tagScroll.isHidden = tags.isEmpty
        tagHeightConstraint.constant = mode == .discover && !tags.isEmpty ? 38 : 0
        guard !tags.isEmpty else { return }
        tagStack.addArrangedSubview(filterChip(
            title: "All playlists",
            selected: selectedPlaylistTag == nil,
            index: 0,
            action: #selector(playlistTagChipTapped(_:))
        ))
        for (index, tag) in tags.enumerated() {
            tagStack.addArrangedSubview(filterChip(
                title: tag.name,
                selected: tag.slug == selectedPlaylistTag,
                index: index + 1,
                action: #selector(playlistTagChipTapped(_:))
            ))
        }
    }

    @objc private func genreChipTapped(_ sender: UIButton) {
        let genre: QobuzCatalogGenre?
        if sender.tag == 0 {
            genre = nil
        } else {
            let index = sender.tag - 1
            guard genres.indices.contains(index) else { return }
            genre = genres[index]
        }
        guard selectedGenreID != genre?.id else { return }
        selectedGenreID = genre?.id
        selectedPlaylistTag = nil
        updateGenreFilters()
        loadDiscovery()
    }

    @objc private func playlistTagChipTapped(_ sender: UIButton) {
        let tags = discoveryResponse?.containers?.playlistsTags?.data?.items ?? []
        let tag: String?
        if sender.tag == 0 {
            tag = nil
        } else {
            let index = sender.tag - 1
            guard tags.indices.contains(index) else { return }
            tag = tags[index].slug
        }
        guard selectedPlaylistTag != tag else { return }
        selectedPlaylistTag = tag
        updatePlaylistTagFilters()
        requestID += 1
        discoveryGeneration = requestID
        resetPlaylistPages()
        statusLabel.text = tag.map { "Playlists tagged ‘\($0)’ on Qobuz" } ?? mode.discoveryCaption
        buildDiscoveryRows()
        loadPlaylistPage(offset: 0, generation: discoveryGeneration)
    }

    private func resetPlaylistPages() {
        fetchedPlaylists = nil
        playlistTotal = nil
        nextPlaylistOffset = 0
        isLoadingPlaylists = false
        hasMorePlaylists = false
    }

    private func loadDiscovery() {
        requestID += 1
        let generation = requestID
        discoveryGeneration = generation
        discoveryResponse = nil
        resetPlaylistPages()
        rows = []
        table.reloadData()
        statusLabel.text = "Loading Qobuz discovery…"
        updateGenreFilters()
        updatePlaylistTagFilters()

        if !didRequestGenres {
            didRequestGenres = true
            client.catalogGenres { [weak self] result in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if case .success(let genres) = result {
                        self.genres = genres.filter { $0.id != nil && $0.name != nil }
                        self.updateGenreFilters()
                    }
                }
            }
        }

        client.discoveryIndex(genreID: selectedGenreID) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.discoveryGeneration == generation else { return }
                switch result {
                case .failure(let error):
                    self.showError(error)
                case .success(let response):
                    self.discoveryResponse = response
                    self.statusLabel.text = self.mode.discoveryCaption
                    self.updatePlaylistTagFilters()
                    self.buildDiscoveryRows()
                }
            }
        }
        loadPlaylistPage(offset: 0, generation: generation)
    }

    private func loadPlaylistPage(offset: Int, generation: Int) {
        guard !isLoadingPlaylists else { return }
        isLoadingPlaylists = true
        if offset > 0 {
            buildDiscoveryRows()
        }
        client.discoverPlaylists(
            genreID: selectedGenreID,
            tag: selectedPlaylistTag,
            offset: offset,
            limit: 20
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.discoveryGeneration == generation else { return }
                self.isLoadingPlaylists = false
                switch result {
                case .failure:
                    if offset == 0 { self.fetchedPlaylists = nil }
                    self.hasMorePlaylists = false
                    if self.discoveryResponse != nil {
                        self.statusLabel.text = "Qobuz editorial picks · Some playlist filters are unavailable."
                    }
                case .success(let response):
                    var playlists = offset == 0 ? [] : (self.fetchedPlaylists ?? [])
                    var knownIDs = Set(playlists.map(\.id))
                    playlists.append(contentsOf: response.items.filter { knownIDs.insert($0.id).inserted })
                    self.fetchedPlaylists = playlists
                    self.playlistTotal = response.total
                    self.nextPlaylistOffset = (response.offset ?? offset) + response.items.count
                    self.hasMorePlaylists = !response.items.isEmpty && (response.total.map { self.nextPlaylistOffset < $0 }
                        ?? (response.items.count >= (response.limit ?? 20)))
                }
                self.buildDiscoveryRows()
            }
        }
    }

    private func buildDiscoveryRows() {
        guard let containers = discoveryResponse?.containers else {
            table.reloadData()
            return
        }
        rows = []
        var discoveryAlbums: [QobuzCatalogDiscoveryAlbum] = []

        func appendAlbums(_ title: String, from section: QobuzCatalogDiscoverySection<QobuzCatalogDiscoveryAlbum>?) {
            let albums = section?.data?.items ?? []
            guard !albums.isEmpty else { return }
            rows.append(.heading(title))
            rows.append(contentsOf: albums.map { .album(Self.screenDiscoveryAlbum($0)) })
            discoveryAlbums.append(contentsOf: albums)
        }

        appendAlbums("NEW RELEASES", from: containers.newReleases)
        appendAlbums("QOBUZISSIMS", from: containers.qobuzissims)
        appendAlbums("ESSENTIAL DISCOGRAPHY", from: containers.idealDiscography)
        appendAlbums("ALBUM OF THE WEEK", from: containers.albumOfTheWeek)
        appendAlbums("MOST STREAMED", from: containers.mostStreamed)
        appendAlbums("PRESS AWARDS", from: containers.pressAwards)

        let indexedPlaylists = containers.playlists?.data?.items ?? []
        let playlists: [QobuzCatalogPlaylist]
        if let fetchedPlaylists = fetchedPlaylists {
            playlists = fetchedPlaylists.isEmpty && selectedGenreID == nil && selectedPlaylistTag == nil
                ? indexedPlaylists
                : fetchedPlaylists
        } else {
            playlists = selectedPlaylistTag == nil ? indexedPlaylists : []
        }
        if !playlists.isEmpty {
            rows.append(.heading(selectedPlaylistTag == nil ? "PLAYLISTS" : "PLAYLISTS · FILTERED"))
            rows.append(contentsOf: playlists.map(Row.playlist))
            if fetchedPlaylists != nil && hasMorePlaylists {
                rows.append(.loadMorePlaylists)
            }
        }

        var seenArtistIDs = Set<String>()
        let artists = discoveryAlbums.compactMap(\.primaryArtist).filter { artist in
            guard let id = artist.id, let name = artist.name, !name.isEmpty else { return false }
            return seenArtistIDs.insert(id).inserted
        }
        if !artists.isEmpty {
            rows.append(.heading("ARTISTS TO EXPLORE"))
            rows.append(contentsOf: artists.prefix(12).map { .artist(Self.screenProfile($0)) })
        }

        if rows.isEmpty {
            statusLabel.text = "No Qobuz discovery items are available for this filter."
        } else if selectedPlaylistTag != nil {
            statusLabel.text = "Playlists filtered by your selection · Qobuz editorial picks"
        } else {
            statusLabel.text = mode.discoveryCaption
        }
        table.reloadData()
        loadArtwork()
    }

    private func loadLibrary() {
        guard mode.isLibrary, !isLoadingLibrary else { return }
        isLoadingLibrary = true
        libraryError = nil
        requestID += 1
        let currentRequest = requestID
        applyLibraryFilter()
        client.library { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.requestID == currentRequest else { return }
                self.isLoadingLibrary = false
                self.libraryRefreshControl.endRefreshing()
                switch result {
                case .failure(let error):
                    // Keep an already loaded library available if refresh fails.
                    self.libraryError = error.localizedDescription
                case .success(let library):
                    switch self.mode {
                    case .albums:
                        self.libraryRows = (library.albums?.items ?? []).map { .album(Self.screenAlbum($0)) }
                    case .artists:
                        self.libraryRows = (library.artists?.items ?? []).map { .artist(Self.screenProfile($0)) }
                    case .tracks:
                        self.libraryRows = (library.tracks?.items ?? []).map { .track(Self.screenTrack($0)) }
                    case .discover, .search: break
                    }
                    self.didLoadLibrary = true
                }
                self.applyLibraryFilter()
                self.loadArtwork()
            }
        }
    }

    private func applyLibraryFilter() {
        let query = (searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        rows = libraryRows.filter { row in
            guard !query.isEmpty else { return true }
            let text: String
            switch row {
            case .album(let album): text = [album.title, album.artist, album.year, album.genre].joined(separator: " ")
            case .artist(let artist): text = artist.name
            case .track(let track): text = [track.title, track.artist, track.album].joined(separator: " ")
            case .heading, .playlist, .loadMorePlaylists: return false
            }
            return text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
        if isLoadingLibrary {
            statusLabel.text = didLoadLibrary ? "Refreshing your Qobuz library…" : "Loading your Qobuz library…"
        } else if let error = libraryError {
            statusLabel.text = didLoadLibrary ? "Library refresh failed: \(error)" : error
        } else if rows.isEmpty {
            statusLabel.text = query.isEmpty
                ? "No saved \(mode.accessibilityName) in your Qobuz library."
                : "No saved \(mode.accessibilityName) matching ‘\(query)’"
        } else {
            statusLabel.text = query.isEmpty
                ? "\(rows.count) saved \(mode.accessibilityName) · Qobuz library"
                : "\(rows.count) saved \(mode.accessibilityName) matching ‘\(query)’"
        }
        table.reloadData()
    }

    private func search(query: String) {
        guard !mode.isLibrary else { applyLibraryFilter(); return }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        requestID += 1
        guard !query.isEmpty else { rows = []; table.reloadData(); statusLabel.text = "Search the Qobuz catalog"; return }
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

    private func loadPlaylistDetail(_ playlist: QobuzCatalogPlaylist) {
        playlistDetailRequestID += 1
        let currentRequest = playlistDetailRequestID
        statusLabel.text = "Loading ‘\(playlist.name)’…"
        client.playlist(id: playlist.id) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, self.playlistDetailRequestID == currentRequest else { return }
                switch result {
                case .failure(let error):
                    self.statusLabel.text = error.localizedDescription
                case .success(let detail):
                    self.statusLabel.text = self.mode.discoveryCaption
                    self.onPlaylistSelected?(detail)
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
        // A saved library may contain thousands of tracks. Load its artwork on
        // display rather than starting one network request for every library row.
        guard !mode.isLibrary else { return }
        for row in rows {
            let url: URL?
            switch row {
            case .heading: continue
            case .track(let track): url = track.artworkURL
            case .album(let album): url = album.artworkURL
            case .artist(let artist): url = artist.artworkURL
            case .playlist(let playlist): url = playlist.artworkURL
            case .loadMorePlaylists: continue
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
        if mode.isLibrary {
            applyLibraryFilter()
            return
        }
        // Editing or clearing the query invalidates an older catalog response.
        requestID += 1
        guard searchText.isEmpty else { return }
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
            cell.detailTextLabel?.text = nil
            cell.backgroundColor = DesignSystem.controlFill
            cell.selectionStyle = .none
        case .track(let track):
            configure(cell, title: track.title, subtitle: "\(track.artist) · \(track.album)", artworkURL: track.artworkURL)
        case .album(let album):
            configure(cell, title: album.title, subtitle: [album.artist, album.year].filter { !$0.isEmpty }.joined(separator: " · "), artworkURL: album.artworkURL)
        case .artist(let artist):
            configure(cell, title: artist.name, subtitle: artist.subtitle, artworkURL: artist.artworkURL, rounded: true)
        case .playlist(let playlist):
            let count = playlist.tracksCount.map { "\($0) tracks" } ?? "Qobuz playlist"
            let subtitle = [playlist.owner?.name, count].compactMap { $0 }.joined(separator: " · ")
            configure(cell, title: playlist.name, subtitle: subtitle, artworkURL: playlist.artworkURL)
        case .loadMorePlaylists:
            cell.textLabel?.text = isLoadingPlaylists ? "Loading more playlists…" : "Load more playlists"
            cell.textLabel?.font = DesignSystem.font(12, weight: .semibold)
            cell.textLabel?.textColor = DesignSystem.accent
            cell.detailTextLabel?.text = nil
            cell.backgroundColor = DesignSystem.pageBackground
            cell.accessoryType = .none
        }
        cell.accessibilityIdentifier = "qobuz.catalogRow.\(indexPath.row)"
        return cell
    }

    private func configure(_ cell: UITableViewCell, title: String, subtitle: String, artworkURL: URL?, rounded: Bool = false) {
        cell.textLabel?.text = title
        cell.textLabel?.font = DesignSystem.font(13, weight: .semibold)
        cell.textLabel?.textColor = DesignSystem.primaryText
        cell.detailTextLabel?.text = subtitle
        cell.detailTextLabel?.font = DesignSystem.font(10)
        cell.detailTextLabel?.textColor = DesignSystem.secondaryText
        cell.backgroundColor = DesignSystem.pageBackground
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator
        cell.imageView?.image = artworkURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: "remote|\($0.absoluteString)|128") }
        cell.imageView?.layer.cornerRadius = rounded ? 23 : 5
        cell.imageView?.clipsToBounds = true
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        guard mode.isLibrary, rows.indices.contains(indexPath.row), cell.imageView?.image == nil,
              let url = artworkURL(for: rows[indexPath.row]) else { return }
        ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: 128) { [weak self, weak cell] image in
            guard let self = self, let cell = cell, let image = image,
                  self.table.indexPath(for: cell) == indexPath,
                  self.rows.indices.contains(indexPath.row),
                  self.artworkURL(for: self.rows[indexPath.row]) == url else { return }
            cell.imageView?.image = image
            cell.setNeedsLayout()
        }
    }

    private func artworkURL(for row: Row) -> URL? {
        switch row {
        case .track(let track): return track.artworkURL
        case .album(let album): return album.artworkURL
        case .artist(let artist): return artist.artworkURL
        case .playlist(let playlist): return playlist.artworkURL
        case .heading, .loadMorePlaylists: return nil
        }
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        guard rows.indices.contains(indexPath.row) else { return 72 }
        switch rows[indexPath.row] {
        case .heading: return 38
        case .loadMorePlaylists: return 50
        default: return 72
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        switch rows[indexPath.row] {
        case .track(let track): onTrackSelected?(track)
        case .album(let album): onAlbumSelected?(album)
        case .artist(let artist): onArtistSelected?(artist)
        case .playlist(let playlist): loadPlaylistDetail(playlist)
        case .loadMorePlaylists:
            loadPlaylistPage(offset: nextPlaylistOffset, generation: discoveryGeneration)
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
        return ScreenProfile(id: mapped.id, name: mapped.name, subtitle: mapped.subtitle, information: mapped.information, artwork: artwork, artworkURL: mapped.artworkURL, albums: mapped.albums, tracks: mapped.tracks)
    }

    private static func screenDiscoveryAlbum(_ source: QobuzCatalogDiscoveryAlbum) -> ScreenAlbum {
        let artist = source.primaryArtist?.name ?? "Unknown Artist"
        let artwork = source.artworkURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: $0.absoluteString) }
        return ScreenAlbum(
            id: source.id,
            title: source.title,
            artist: artist,
            year: source.year,
            genre: "",
            quality: "",
            artwork: artwork,
            artworkURL: source.artworkURL,
            tracks: []
        )
    }

    private static func screenProfile(_ source: QobuzCatalogDiscoveryArtist) -> ScreenProfile {
        guard let id = source.id, let name = source.name else {
            return ScreenProfile(id: "", name: source.name ?? "Unknown Artist", subtitle: "Artist on Qobuz", information: "", artworkURL: source.artworkURL, albums: [])
        }
        let artwork = source.artworkURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: $0.absoluteString) }
        return ScreenProfile(id: id, name: name, subtitle: "Artist on Qobuz", information: "", artwork: artwork, artworkURL: source.artworkURL, albums: [])
    }
}

private extension QobuzCatalogViewController.Mode {
    var isLibrary: Bool {
        switch self {
        case .albums, .artists, .tracks: return true
        case .discover, .search: return false
        }
    }

    var accessibilityName: String {
        switch self { case .discover: return "discover"; case .search: return "search"; case .albums: return "albums"; case .artists: return "artists"; case .tracks: return "tracks" }
    }

    var discoveryCaption: String {
        switch self { case .discover: return "Qobuz editorial discovery"; case .albums: return "Saved Qobuz albums"; case .artists: return "Saved Qobuz artists"; case .tracks: return "Saved Qobuz tracks"; case .search: return "Search the Qobuz catalog" }
    }
}

final class QobuzPlaylistDetailViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    var onTrackSelected: ((ScreenTrack) -> Void)?
    var onPlayRequested: (([ScreenTrack], Bool) -> Void)?

    private let playlist: QobuzCatalogPlaylist
    private let tracks: [ScreenTrack]
    private let header = UIStackView()
    private let table = UITableView(frame: .zero, style: .plain)
    private let emptyLabel = UILabel()

    init(playlist: QobuzCatalogPlaylist) {
        self.playlist = playlist
        self.tracks = (playlist.tracks?.items ?? []).map { source in
            let mapped = QobuzCatalogMapper.track(source)
            let artwork = source.album?.imageURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: $0.absoluteString) }
            return ScreenTrack(
                id: mapped.id,
                title: mapped.title,
                artist: mapped.artist,
                album: mapped.album,
                quality: mapped.quality,
                artwork: artwork,
                artworkURL: mapped.artworkURL,
                catalogAlbumID: mapped.catalogAlbumID,
                catalogArtistID: mapped.catalogArtistID,
                duration: mapped.duration
            )
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = DesignSystem.pageBackground
        view.accessibilityIdentifier = "qobuz.playlistDetail"
        header.translatesAutoresizingMaskIntoConstraints = false
        header.axis = .vertical
        header.alignment = .fill
        header.spacing = 10
        table.translatesAutoresizingMaskIntoConstraints = false
        table.backgroundColor = DesignSystem.pageBackground
        table.separatorColor = DesignSystem.separator
        table.rowHeight = 70
        table.dataSource = self
        table.delegate = self
        table.register(QobuzCatalogCell.self, forCellReuseIdentifier: "playlistTrack")

        let closeButton = UIButton(type: .system)
        closeButton.setTitle("Done", for: .normal)
        closeButton.contentHorizontalAlignment = .left
        closeButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        let title = UILabel()
        title.text = playlist.name
        title.font = DesignSystem.font(25, weight: .bold)
        title.textColor = DesignSystem.primaryText
        title.numberOfLines = 2
        let owner = playlist.owner?.name ?? "Qobuz playlist"
        let metadata = UILabel()
        metadata.text = [owner, playlist.tracksCount.map { "\($0) tracks" }].compactMap { $0 }.joined(separator: " · ")
        metadata.font = DesignSystem.font(12, weight: .medium)
        metadata.textColor = DesignSystem.secondaryText
        let description = UILabel()
        description.text = playlist.description
        description.font = DesignSystem.font(12)
        description.textColor = DesignSystem.secondaryText
        description.numberOfLines = 3
        description.isHidden = (playlist.description ?? "").isEmpty

        let actions = UIStackView()
        actions.axis = .horizontal
        actions.spacing = 12
        let playButton = actionButton(title: "Play")
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        playButton.isEnabled = !tracks.isEmpty
        let shuffleButton = actionButton(title: "Shuffle")
        shuffleButton.addTarget(self, action: #selector(shuffleTapped), for: .touchUpInside)
        shuffleButton.isEnabled = !tracks.isEmpty
        actions.addArrangedSubview(playButton)
        actions.addArrangedSubview(shuffleButton)
        [closeButton, title, metadata, description, actions].forEach(header.addArrangedSubview)

        emptyLabel.text = "This playlist has no available tracks."
        emptyLabel.font = DesignSystem.font(13)
        emptyLabel.textColor = DesignSystem.secondaryText
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        if tracks.isEmpty { table.backgroundView = emptyLabel }
        view.addSubview(header)
        view.addSubview(table)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            table.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            table.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            table.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        loadArtwork()
    }

    private func actionButton(title: String) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = DesignSystem.font(13, weight: .semibold)
        button.setTitleColor(DesignSystem.primaryText, for: .normal)
        button.backgroundColor = DesignSystem.actionFill
        button.layer.cornerRadius = 9
        button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 18, bottom: 10, right: 18)
        return button
    }

    private func loadArtwork() {
        for track in tracks {
            guard let url = track.artworkURL else { continue }
            ArtworkImagePipeline.shared.image(forRemoteURL: url, maximumPixelSize: 128) { [weak self] image in
                guard image != nil else { return }
                self?.table.reloadData()
            }
        }
    }

    @objc private func doneTapped() { dismiss(animated: true) }
    @objc private func playTapped() { onPlayRequested?(tracks, false) }
    @objc private func shuffleTapped() { onPlayRequested?(tracks, true) }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { tracks.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "playlistTrack", for: indexPath)
        guard tracks.indices.contains(indexPath.row) else { return cell }
        let track = tracks[indexPath.row]
        cell.textLabel?.text = track.title
        cell.textLabel?.font = DesignSystem.font(13, weight: .semibold)
        cell.textLabel?.textColor = DesignSystem.primaryText
        cell.detailTextLabel?.text = "\(track.artist) · \(track.album)"
        cell.detailTextLabel?.font = DesignSystem.font(10)
        cell.detailTextLabel?.textColor = DesignSystem.secondaryText
        cell.backgroundColor = DesignSystem.pageBackground
        cell.imageView?.image = track.artworkURL.flatMap { ArtworkImagePipeline.shared.cachedImage(for: "remote|\($0.absoluteString)|128") }
        cell.imageView?.layer.cornerRadius = 5
        cell.imageView?.clipsToBounds = true
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard tracks.indices.contains(indexPath.row) else { return }
        onTrackSelected?(tracks[indexPath.row])
    }
}

