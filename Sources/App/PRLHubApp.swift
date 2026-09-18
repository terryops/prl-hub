import SwiftUI

/// Entry point for the Pearl Hub native app. One SwiftUI `App` shared by the macOS
/// and iOS targets (see ../../project.yml). Platform differences are isolated
/// with `#if os(...)` rather than separate app structs.
@main
struct PRLHubApp: App {
    // APNs token callbacks + foreground banners for price alerts (PriceAlerts.swift).
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .windowResizability(.contentMinSize)
        #endif
    }
}
