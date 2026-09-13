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
        #if DEBUG
        // Deterministic simulator entry points for visual and loading regression checks.
        if CommandLine.arguments.contains("--preview-race") || CommandLine.arguments.contains("--preview-world") {
            let mode: GameMode = CommandLine.arguments.contains("--preview-world") ? .openWorld : .race
            win.rootViewController = GameViewController(difficulty: .easy, mode: mode, quality: .medium)
        }
        #endif
        win.makeKeyAndVisible()
        window = win
        return true
    }
}
