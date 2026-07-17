import Foundation
import NetworkExtension

// A macOS system extension is a plain executable and must supply its own entry
// point. (The iOS app-extension variant instead links NSExtensionMain from the
// extension SDK, so it has no main.swift — this file is a member of the
// PacketTunnelSysEx target only.)
//
// startSystemExtensionMode() reads the NetworkExtension/NEProviderClasses map
// from Info-macOS.plist and instantiates PacketTunnelProvider when the system
// starts the tunnel; dispatchMain() then parks the main thread so the process
// stays alive to service it.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}

dispatchMain()
