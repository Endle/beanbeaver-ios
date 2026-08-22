import SwiftUI

@main
struct BeanBeaverApp: App {
    // Before any window exists: `UITabBar.appearance()` is a proxy consulted
    // when a bar is created, so setting it after the fact leaves the first one
    // drawn with the system's colours.
    init() { TabBarAppearance.apply() }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Fetch entitlements once, and keep listening for changes for
                // the life of the process — see `Entitlements.start()`.
                .task { await Entitlements.shared.start() }
        }
    }
}
