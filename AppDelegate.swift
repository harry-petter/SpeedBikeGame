import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {

    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        let win = UIWindow(frame: UIScreen.main.bounds)
        win.rootViewController = MenuViewController()
        win.makeKeyAndVisible()
        window = win
        return true
    }
}
