import SwiftUI

/// Entry point for the Pearl Hub native app. One SwiftUI `App` shared by the macOS
/// and iOS targets (see ../../project.yml). Platform differences are isolated
/// with `#if os(...)` rather than separate app structs.
@main
struct PRLHubApp: App {
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
