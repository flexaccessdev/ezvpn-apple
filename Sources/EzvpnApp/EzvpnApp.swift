import SwiftUI

@main
struct EzvpnApp: App {
    @StateObject private var manager = TunnelsManager()

    var body: some Scene {
        WindowGroup {
            TunnelListView()
                .environmentObject(manager)
        }
    }
}
