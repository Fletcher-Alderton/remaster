import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var coordinator: SyncCoordinator

    var body: some View {
        NavigationSplitView {
            List {
                Label("Sync", systemImage: "ipod")
                Label("Play history", systemImage: "clock.arrow.circlepath")
                Label("Last.fm", systemImage: "waveform")
            }
            .navigationTitle("Qobuz Sync")
            .frame(minWidth: 175)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    syncCard
                    lastFMCard
                    historyCard
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("iPod Qobuz Sync")
                    .font(.largeTitle.bold())
                Text(coordinator.statusMessage)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if coordinator.isSyncing || coordinator.isLastFMWorking {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    private var syncCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                Label(coordinator.deviceDescription, systemImage: "cable.connector")
                    .foregroundStyle(coordinator.deviceDescription.hasPrefix("No") ? .secondary : .primary)
                HStack {
                    TextField("Qobuz folder", text: $coordinator.sourceFolderPath)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            coordinator.saveSourceFolderPath()
                        }
                    Button("Choose…") { coordinator.chooseSourceFolder() }
                    Button("Sync now") { coordinator.syncNow() }
                        .buttonStyle(.borderedProminent)
                        .disabled(coordinator.isSyncing)
                }
                Toggle("Sync automatically when the iPod is connected", isOn: Binding(
                    get: { coordinator.autoSyncEnabled },
                    set: { coordinator.setAutoSync($0) }
                ))
                Toggle("Launch Qobuz Sync when I log in", isOn: Binding(
                    get: { coordinator.launchAtLoginEnabled },
                    set: { coordinator.setLaunchAtLogin($0) }
                ))
                Text("Changed music and cover files are copied into the Music app over USB. Files already on the iPod are left alone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("Music transfer", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
        }
    }

    private var lastFMCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let username = coordinator.authorizedUsername, coordinator.hasLastFMSession {
                    HStack {
                        Label("Connected as \(username)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Disconnect", role: .destructive) {
                            coordinator.disconnectLastFM()
                        }
                    }
                }
                HStack {
                    TextField("API key", text: $coordinator.apiKey)
                    SecureField("Shared secret", text: $coordinator.sharedSecret)
                }
                .textFieldStyle(.roundedBorder)
                HStack {
                    if coordinator.isWaitingForLastFMApproval {
                        Button("Open approval page") {
                            coordinator.openPendingLastFMApprovalPage()
                        }
                    } else {
                        Button("Authorize in browser") {
                            coordinator.beginLastFMAuthorization()
                        }
                        .disabled(coordinator.isLastFMWorking)
                    }
                    Button("I've approved it — finish") {
                        coordinator.completeLastFMAuthorization()
                    }
                    Spacer()
                    Text("\(coordinator.pendingScrobbleCount) pending")
                        .foregroundStyle(.secondary)
                    Button("Upload pending plays") {
                        coordinator.scrobbleNow()
                    }
                    .disabled(!coordinator.hasLastFMSession || coordinator.isLastFMWorking)
                }
                HStack(spacing: 8) {
                    if coordinator.isWaitingForLastFMApproval {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(coordinator.lastFMStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("The shared secret and Last.fm session are stored in your Mac keychain. Eligible plays upload automatically after each iPod sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
        } label: {
            Label("Last.fm", systemImage: "dot.radiowaves.left.and.right")
                .font(.headline)
        }
    }

    private var historyCard: some View {
        GroupBox {
            if coordinator.playbackHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("No imported plays")
                        .font(.headline)
                    Text("Play something on the iPod, then connect it and sync.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(coordinator.playbackHistory.prefix(100)) { item in
                        HStack(spacing: 12) {
                            statusIcon(item.state)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.event.title)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Text("\(item.event.artist) · \(item.event.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(duration(item.event.listenedSeconds))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                            Text(item.state.rawValue.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                        }
                        .help(item.stateMessage ?? "")
                        .padding(.vertical, 8)
                        Divider()
                    }
                }
            }
        } label: {
            Label("Play history", systemImage: "clock")
                .font(.headline)
        }
    }

    @ViewBuilder
    private func statusIcon(_ state: ScrobbleState) -> some View {
        switch state {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.orange)
        case .scrobbled:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .ineligible:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
