import SwiftUI

@main
struct EzvpnApp: App {
    @StateObject private var manager = TunnelsManager()

    var body: some Scene {
        WindowGroup {
            TunnelListView()
                .environmentObject(manager)
        }
        #if os(macOS)
        .defaultSize(width: 480, height: 600)
        #endif
    }
}
