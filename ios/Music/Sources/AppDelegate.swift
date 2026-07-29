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
        let window = UIWindow(frame: UIScreen.main.bounds)
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
