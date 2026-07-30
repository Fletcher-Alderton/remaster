import SwiftUI

@main
struct QobuzSyncApp: App {
    @StateObject private var coordinator = SyncCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .frame(minWidth: 760, minHeight: 620)
                .task {
                    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                        coordinator.start()
                    }
                }
        }
        .windowStyle(.titleBar)
    }
}
