import SwiftUI

@main
struct BeanBeaverApp: App {
    @Environment(\.scenePhase) private var scenePhase

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
                // `-benchSpend`: the spend-seam benchmark. Not under `#if
                // DEBUG` because its numbers are only meaningful from a Release
                // build — see `SpendPerf`.
                .task { if SpendPerf.isRequested { await SpendPerf.run() } }
        }
        // `SpendStore` writes off the main actor now, so the suspend is where
        // the pending write has to be waited on — see `flushPendingWrites`.
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { SpendStore.shared.flushPendingWrites() }
        }
    }
}
