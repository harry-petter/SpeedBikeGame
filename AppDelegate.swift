import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // One-time reset: track length changed from 3200 → 6400, old records are invalid
        let migrationKey = "trackV2_reset"
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            BestTimes.resetAll()
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.rootViewController =  MenuViewController()
        win.makeKeyAndVisible()
        window = win
        return true
    }
}
