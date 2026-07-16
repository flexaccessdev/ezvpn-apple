import SwiftUI
#if os(macOS)
import AppKit
#endif

enum EzvpnScene {
    static let mainWindowID = "main"
}

@main
struct Ezvpn: App {
    @StateObject private var manager = TunnelsManager()

    var body: some Scene {
        #if os(macOS)
        Window("ezvpn", id: EzvpnScene.mainWindowID) {
            TunnelListView()
                .environmentObject(manager)
                .onAppear {
                    NSApplication.shared.setActivationPolicy(.regular)
                }
                .onDisappear {
                    NSApplication.shared.setActivationPolicy(.accessory)
                }
        }
        .defaultSize(width: 480, height: 600)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(manager)
        } label: {
            Image(manager.menuBarIconState.imageName)
                .accessibilityLabel(Text(manager.menuBarIconState.accessibilityLabel))
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup {
            TunnelListView()
                .environmentObject(manager)
        }
        #endif
    }
}
