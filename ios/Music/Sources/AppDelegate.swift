import UIKit

@UIApplicationMain
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        if ProcessInfo.processInfo.arguments.contains("-reset-ui-test-state"),
           let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        var windowFrame = UIScreen.main.bounds
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("-ipod-preview") {
            windowFrame = CGRect(
                x: (windowFrame.width - DesignSystem.screenWidth) / 2,
                y: (windowFrame.height - DesignSystem.screenHeight) / 2,
                width: DesignSystem.screenWidth,
                height: DesignSystem.screenHeight
            )
        }
        #endif
        if let url = Bundle.main.url(forResource: QobuzPersonalCredentialImport.resourceName, withExtension: "json") {
            do {
                try QobuzPersonalCredentialImport.importIfNeeded(data: Data(contentsOf: url)) {
                    try QobuzCredentialStore.shared.save($0)
                }
            } catch {
                // Never log the payload or decoded account credentials.
                NSLog("Personal Qobuz credential import failed; use account sign-in to retry.")
            }
        }
        // Ships the parametric EQ profiles in Resources/EQ into the profile library, so a
        // personal correction does not have to be pasted in by hand on a fresh install.
        EQProfileStore.shared.importBundledProfilesIfNeeded()

        let window = UIWindow(frame: windowFrame)
        window.backgroundColor = DesignSystem.pageBackground
        window.rootViewController = RootViewController()
        window.makeKeyAndVisible()
        self.window = window
        ThemeManager.startAutomaticMonitoring()
        return true
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        ThemeManager.refresh(force: false)
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        return .portrait
    }
}
