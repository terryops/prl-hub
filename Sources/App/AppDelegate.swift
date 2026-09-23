import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// App delegate for the few things SwiftUI's App lifecycle doesn't cover:
// APNs token callbacks (price alerts, see PriceAlerts.swift), foreground
// notification banners, and — on iPhone — the 锁定竖屏 orientation lock.

final class PushDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Show price alerts as banners even while the app is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
        // A price alert that just arrived has switched itself off server-side.
        Task { @MainActor in await PriceAlertStore.shared.refresh() }
    }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let push = PushDelegate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = push
        Task { @MainActor in PriceAlertStore.shared.launch() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PriceAlertStore.shared.didRegister(tokenData: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PriceAlertStore.shared.didFailToRegister(error) }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }
}

/// 设置 → 外观 → 锁定竖屏 (iPhone only, ON by default). The Info.plist still
/// declares the landscape orientations so turning the lock off lets the app rotate.
/// iPad keeps every orientation — multitasking requires it.
enum OrientationLock {
    static let key = "ui.lockPortrait"

    static var isOn: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    static var mask: UIInterfaceOrientationMask {
        guard UIDevice.current.userInterfaceIdiom == .phone else { return .all }
        return isOn ? .portrait : .allButUpsideDown
    }

    /// Re-query the mask right away; rotate back to portrait if the lock was just
    /// switched on while the phone is held sideways.
    @MainActor static func apply() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                var vc = window.rootViewController
                while let v = vc {
                    v.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = v.presentedViewController
                }
            }
            if isOn, UIDevice.current.userInterfaceIdiom == .phone {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}
#else
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let push = PushDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = push
        Task { @MainActor in PriceAlertStore.shared.launch() }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in PriceAlertStore.shared.didRegister(tokenData: deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Task { @MainActor in PriceAlertStore.shared.didFailToRegister(error) }
    }
}
#endif
