import SwiftUI

@main
struct BeanBeaverApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                // Fetch entitlements once, and keep listening for changes for
                // the life of the process — see `Entitlements.start()`.
                .task { await Entitlements.shared.start() }
        }
    }
}
