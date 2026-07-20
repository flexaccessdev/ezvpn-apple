import NetworkExtension
import Network
import Darwin
import os.log
import TunnelCore

/// The Packet Tunnel Provider: the process the OS runs to carry VPN traffic.
///
/// It bridges Apple's `NEPacketTunnelProvider` to the Rust core (libezvpn.a):
/// configure the tunnel interface from the server's handshake, hand the `utun`
/// fd to Rust, and let Rust run the framed IP data loop over a reliable QUIC stream.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "ezvpn.PacketTunnel", category: "tunnel")
    private var handle: OpaquePointer?

    /// Serializes backend teardown and runtime-config queries, mirroring
    /// WireGuardAdapter's private work queue: `stopTunnel` completes only
    /// after `ezvpn_stop` has actually returned, and never blocks the
    /// provider's calling queue while the Rust side shuts down.
    private let workQueue = DispatchQueue(label: "ezvpn.PacketTunnel.workQueue")

    /// What was actually applied to the interface (assigned addresses, tunnel
    /// routes, bypass routes, MTU), kept so the app can query it over
    /// `handleAppMessage` — the same runtime-configuration mechanism the
    /// WireGuard app uses. Accessed on `workQueue` only.
    private var runtimeConfig: [String: Any]?

    /// Set when `stopTunnel` runs while `ezvpn_connect` is still in flight
    /// (there is no handle to stop yet). The connect path checks it once the
    /// handshake returns and tears down instead of proceeding. Accessed on
    /// `workQueue` only.
    private var stopRequested = false

    /// Watches the physical network while the tunnel runs (same shape as
    /// WireGuardAdapter's monitor, but simpler policy): any change to the
    /// underlay — Wi-Fi ↔ cellular, different Wi-Fi, network lost — cancels the
    /// tunnel instead of trying to migrate the QUIC session across it. The user
    /// reconnects on the new network. Accessed on `workQueue` only.
    private var networkMonitor: NWPathMonitor?
    /// Fingerprint of the physical path at tunnel start, captured from the
    /// monitor's initial callback; a later mismatch is a network change.
    private var networkPathKey: String?

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        ezvpn_init_logging()

        guard
            let proto = protocolConfiguration as? NETunnelProviderProtocol,
            let conf = proto.providerConfiguration
        else {
            completionHandler(Self.error("missing providerConfiguration"))
            return
        }

        let serverNodeID = conf["server_node_id"] as? String ?? ""
        let authToken: String
        do {
            #if os(macOS)
            // The system extension is a root daemon: it cannot see the user's
            // data-protection keychain, so the app hands the token over in the
            // start options on every app-initiated connect, and the provider
            // persists it in the System keychain (the daemon keychain) so
            // system-initiated restarts can connect without the app.
            guard
                let idString = conf[ProviderConfigKey.profileID] as? String,
                let profileID = UUID(uuidString: idString)
            else {
                completionHandler(Self.error("missing profile_id in providerConfiguration"))
                return
            }
            if let optionToken = options?[TunnelStartOption.authToken] as? String,
               !optionToken.isEmpty {
                authToken = optionToken
                do {
                    try AuthTokenKeychain.persistDaemonToken(optionToken, for: profileID)
                } catch {
                    // The in-hand token still works for this session; only
                    // app-less restarts are affected. Log and continue.
                    os_log(
                        "could not persist auth token to the System keychain: %{public}@",
                        log: log, type: .error, error.localizedDescription)
                }
            } else {
                authToken = try AuthTokenKeychain.daemonToken(for: profileID)
            }
            #else
            guard let passwordReference = proto.passwordReference else {
                completionHandler(Self.error("missing auth-token Keychain reference"))
                return
            }
            authToken = try AuthTokenKeychain.token(for: passwordReference)
            #endif
        } catch {
            completionHandler(Self.error("failed to load auth token: \(error.localizedDescription)"))
            return
        }
        let relayURLs = conf["relay_urls"] as? [String] ?? []
        let routes = conf["routes"] as? [String] ?? []
        let routes6 = conf["routes6"] as? [String] ?? []
        #if os(iOS)
        let dnsServers = conf["dns_servers"] as? [String] ?? []
        let dnsMatchDomains = conf["dns_match_domains"] as? [String] ?? []
        #else
        // macOS deliberately leaves the system's DNS configuration untouched.
        let dnsServers: [String] = []
        let dnsMatchDomains: [String] = []
        #endif

        // Refuse to start when a configured split-tunnel prefix overlaps the
        // network the device is currently on: routing the local subnet into the
        // tunnel would cut off on-link hosts — including the gateway carrying
        // the tunnel's own underlay traffic.
        if let conflict = splitTunnelConflict(routes: routes, routes6: routes6) {
            os_log("%{public}@", log: log, type: .error, conflict)
            completionHandler(Self.error(conflict))
            return
        }

        // Build the FFI config JSON. routes/routes6 are forwarded so the core can
        // compute which server underlay addresses overlap and must be excluded.
        let configDict: [String: Any] = [
            "server_node_id": serverNodeID,
            "auth_token": authToken,
            "relay_urls": relayURLs,
            "routes": routes,
            "routes6": routes6,
        ]
        guard
            let configData = try? JSONSerialization.data(withJSONObject: configDict),
            let configStr = String(data: configData, encoding: .utf8)
        else {
            completionHandler(Self.error("failed to encode config JSON"))
            return
        }

        // ezvpn_connect blocks until connect + handshake succeed, fail, or time
        // out (bounded by connect_timeout_secs in the Rust core). Run it off the
        // provider's calling queue: blocking that queue would also block delivery
        // of stopTunnel, so cancelling a connect to an offline server would hang
        // at "disconnecting" until the OS kills the process.
        DispatchQueue.global(qos: .userInitiated).async {
            self.connectAndStart(configStr: configStr, routes: routes, routes6: routes6,
                                 dnsServers: dnsServers, dnsMatchDomains: dnsMatchDomains,
                                 completionHandler: completionHandler)
        }
    }

    /// The blocking half of `startTunnel`: connect + handshake via the Rust
    /// core, then apply tunnel settings. Runs on a background queue.
    private func connectAndStart(
        configStr: String,
        routes: [String],
        routes6: [String],
        dnsServers: [String],
        dnsMatchDomains: [String],
        completionHandler: @escaping (Error?) -> Void
    ) {
        // ezvpn_connect: connect + handshake. Result/error JSON lands in `buf`.
        var buf = [CChar](repeating: 0, count: 4096)
        let handle = configStr.withCString { cstr in
            ezvpn_connect(cstr, &buf, buf.count)
        }
        let resultStr = String(cString: buf)

        guard let handle else {
            os_log("ezvpn_connect failed: %{public}@", log: log, type: .error, resultStr)
            completionHandler(Self.error("connect failed: \(resultStr)"))
            return
        }
        // `handle` is stored into `self.handle` only once all validation below
        // has passed (just before setTunnelNetworkSettings), so these pre-flight
        // error paths only need to stop the local handle. All access to
        // `self.handle` is confined to `workQueue`, mirroring `runtimeConfig`,
        // so stopTunnel and the async completion below can never race into a
        // double `ezvpn_stop` (which would double-free the handle). A stop that
        // arrived while the connect was in flight is caught via `stopRequested`
        // on `workQueue` below.
        os_log("handshake result: %{public}@", log: log, type: .info, resultStr)

        guard
            let data = resultStr.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let mtu = obj["mtu"] as? Int
        else {
            ezvpn_stop(handle)
            completionHandler(Self.error("bad network config: \(resultStr)"))
            return
        }

        // Per-family fields are present only for assigned families (null otherwise).
        let v4ip = obj["assigned_ip"] as? String
        let v4mask = obj["netmask"] as? String
        let v4gw = obj["gateway"] as? String
        let v6ip = obj["assigned_ip6"] as? String
        let v6prefix = obj["prefix_len6"] as? Int
        let v6gw = obj["gateway6"] as? String
        let excluded = obj["excluded_routes"] as? [String] ?? []
        let excluded6 = obj["excluded_routes6"] as? [String] ?? []

        // Tunnel needs a remote-address label; any assigned gateway works.
        guard let remoteAddr = v4gw ?? v6gw else {
            ezvpn_stop(handle)
            completionHandler(Self.error("no gateway in network config: \(resultStr)"))
            return
        }

        // Configure the tunnel interface. Split tunnel: only the configured
        // prefixes are routed through us; overlapping server underlay addresses
        // are carved back out via excludedRoutes; everything else stays off.
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remoteAddr)

        // User route lists are optional: the server advertises a host mask
        // (/32, /128), so the assigned address is on-link to itself only and the
        // gateway is routed explicitly as a host route (see ipv4/ipv6
        // InterfaceRoutes). That keeps the server side of the tunnel (e.g.
        // 10.124.0.1) reachable with no configuration. Extra routes widen the
        // split tunnel. Routes for a family the server did not assign can't be
        // applied — warn so it isn't silently ignored.
        if let v4ip, let v4mask {
            let ipv4 = NEIPv4Settings(addresses: [v4ip], subnetMasks: [v4mask])
            ipv4.includedRoutes = Self.ipv4InterfaceRoutes(ip: v4ip, mask: v4mask, gateway: v4gw)
                + routes.compactMap { Self.ipv4Route($0) }
            ipv4.excludedRoutes = excluded.compactMap { Self.ipv4Route($0) }
            settings.ipv4Settings = ipv4
        } else if !routes.isEmpty {
            os_log("ignoring %d IPv4 route(s): server assigned no IPv4 address",
                   log: log, type: .info, routes.count)
        }
        if let v6ip, let v6prefix {
            let ipv6 = NEIPv6Settings(
                addresses: [v6ip], networkPrefixLengths: [NSNumber(value: v6prefix)])
            ipv6.includedRoutes = Self.ipv6InterfaceRoutes(ip: v6ip, prefix: v6prefix, gateway: v6gw)
                + routes6.compactMap { Self.ipv6Route($0) }
            ipv6.excludedRoutes = excluded6.compactMap { Self.ipv6Route($0) }
            settings.ipv6Settings = ipv6
        } else if !routes6.isEmpty {
            os_log("ignoring %d IPv6 route(s): server assigned no IPv6 address",
                   log: log, type: .info, routes6.count)
        }
        settings.mtu = NSNumber(value: mtu)

        #if os(iOS)
        // iOS ignores installed DNS-settings profiles while a VPN is active,
        // making tunnel DNS the only reliable conditional-forwarding path.
        if !dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: dnsServers)
            if !dnsMatchDomains.isEmpty {
                dns.matchDomains = dnsMatchDomains
                // Route-only: match domains must not double as search suffixes.
                dns.matchDomainsNoSearch = true
            }
            settings.dnsSettings = dns
            // A server no tunnel route covers is answered (or not) by the
            // underlying network — usually a misconfiguration for a private
            // resolver, but legitimate for a public one, so warn instead of
            // refusing to start.
            let outside = dnsServersOutsideRoutes(
                servers: dnsServers,
                routes: (settings.ipv4Settings?.includedRoutes ?? []).map(Self.cidrString),
                routes6: (settings.ipv6Settings?.includedRoutes ?? []).map(Self.cidrString))
            if !outside.isEmpty {
                os_log("DNS server(s) %{public}@ not covered by any tunnel route",
                       log: log, type: .error, outside.joined(separator: ", "))
            }
        } else if !dnsMatchDomains.isEmpty {
            os_log("ignoring %d DNS match domain(s): no DNS servers configured",
                   log: log, type: .info, dnsMatchDomains.count)
        }
        #endif

        // Snapshot of what is being applied, for the app's debug UI (served
        // via handleAppMessage). Built from the settings object itself so it
        // reports the routes actually installed, not the ones requested.
        var runtime: [String: Any] = ["mtu": mtu]
        if let ipv4 = settings.ipv4Settings {
            runtime["assigned_ip"] = ipv4.addresses.first
            runtime["included_routes"] = (ipv4.includedRoutes ?? []).map(Self.cidrString)
            runtime["bypass_routes"] = (ipv4.excludedRoutes ?? []).map(Self.cidrString)
        }
        if let ipv6 = settings.ipv6Settings {
            runtime["assigned_ip6"] = ipv6.addresses.first
            runtime["included_routes6"] = (ipv6.includedRoutes ?? []).map(Self.cidrString)
            runtime["bypass_routes6"] = (ipv6.excludedRoutes ?? []).map(Self.cidrString)
        }
        #if os(iOS)
        if let dns = settings.dnsSettings {
            runtime["dns_servers"] = dns.servers
            runtime["dns_match_domains"] = dns.matchDomains ?? []
        }
        #endif

        // Publish the handle so stopTunnel can find it, then keep every further
        // touch of it on workQueue. If stopTunnel already ran while the connect
        // was in flight, it has completed with nothing to stop — tear down the
        // fresh handle here instead of proceeding with a dead session.
        workQueue.async {
            if self.stopRequested {
                ezvpn_stop(handle)
                completionHandler(Self.error("tunnel stopped during connect"))
                return
            }
            self.handle = handle
            self.applySettingsAndRun(settings, runtime: runtime,
                                     completionHandler: completionHandler)
        }
    }

    /// Apply the tunnel network settings and hand the utun fd to the Rust data
    /// loop. Called on `workQueue` with `self.handle` already published.
    private func applySettingsAndRun(
        _ settings: NEPacketTunnelNetworkSettings,
        runtime: [String: Any],
        completionHandler: @escaping (Error?) -> Void
    ) {
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            self.workQueue.async {
                // A concurrent stopTunnel may have already stopped and cleared
                // the handle while these settings were being applied. Re-read it
                // on workQueue and bail if it's gone, so we never run or stop a
                // freed handle.
                guard let handle = self.handle else {
                    completionHandler(Self.error("tunnel stopped during setup"))
                    return
                }
                if let error {
                    os_log("setTunnelNetworkSettings failed: %{public}@",
                           log: self.log, type: .error, error.localizedDescription)
                    ezvpn_stop(handle)
                    self.handle = nil
                    completionHandler(error)
                    return
                }

                guard let fd = self.tunnelFileDescriptor else {
                    ezvpn_stop(handle)
                    self.handle = nil
                    completionHandler(Self.error("could not locate utun fd"))
                    return
                }

                let rc = ezvpn_run(handle, fd)
                if rc != 0 {
                    ezvpn_stop(handle)
                    self.handle = nil
                    completionHandler(Self.error("ezvpn_run failed (rc=\(rc))"))
                    return
                }
                os_log("tunnel running on fd %d", log: self.log, type: .info, fd)
                self.runtimeConfig = runtime
                self.startNetworkMonitor()
                completionHandler(nil)
            }
        }
    }

    /// Begin watching the physical network. Called on `workQueue` once the
    /// data loop is running; the monitor delivers its callbacks on `workQueue`
    /// too, so all state stays queue-confined.
    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: workQueue)
        networkMonitor = monitor
    }

    /// Disconnect on any change to the physical network (runs on `workQueue`).
    /// The monitor fires once immediately on start — that callback records the
    /// baseline; any later mismatch cancels the tunnel via the OS, which calls
    /// `stopTunnel` for the actual teardown and surfaces the reason to the app
    /// through `fetchLastDisconnectError`.
    private func handlePathUpdate(_ path: Network.NWPath) {
        guard handle != nil else { return }
        let key = Self.pathKey(path)
        guard let baseline = networkPathKey else {
            networkPathKey = key
            os_log("network baseline: %{public}@", log: log, type: .info, key)
            return
        }
        guard key != baseline else { return }
        os_log("network changed (%{public}@ -> %{public}@), disconnecting",
               log: log, type: .info, baseline, key)
        // Stop watching before cancelling: teardown itself perturbs the path,
        // and one cancel is enough.
        networkMonitor?.cancel()
        networkMonitor = nil
        cancelTunnelWithError(Self.error("network changed, disconnected"))
    }

    /// Fingerprint of the physical network the tunnel is riding on: overall
    /// reachability plus the usable non-virtual interfaces. Virtual interfaces
    /// are ignored — our own utun shows up in the path and must not trigger a
    /// self-inflicted disconnect.
    private static func pathKey(_ path: Network.NWPath) -> String {
        let physical: [NWInterface.InterfaceType] = [.wifi, .cellular, .wiredEthernet]
        let interfaces = path.availableInterfaces
            .filter { physical.contains($0.type) }
            .map { "\($0.name)(\($0.type))" }
        return "\(path.status):\(interfaces.joined(separator: ","))"
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        os_log("stopTunnel: %d", log: log, type: .info, reason.rawValue)
        // Same shape as wireguard-apple's stopTunnel: stop the backend on the
        // work queue and signal completion only once it has returned, so the
        // OS removes the utun and its routes only after the data plane is
        // actually dead — not while the Rust side may still be writing.
        workQueue.async { [self] in
            // No handle yet means ezvpn_connect is still in flight on its
            // background queue; complete now and let the connect path tear its
            // handle down when it returns (see connectAndStart).
            stopRequested = true
            networkMonitor?.cancel()
            networkMonitor = nil
            networkPathKey = nil
            if let handle {
                ezvpn_stop(handle)
                self.handle = nil
            }
            runtimeConfig = nil
            os_log("tunnel stopped", log: log, type: .info)
            completionHandler()
        }
    }

    /// App <-> extension query channel, using the WireGuard app's protocol:
    /// a single byte selects the query. Byte 0 means "get runtime
    /// configuration" (the applied network config as JSON); byte 1 means
    /// "snapshot the live iroh connection path(s) and custom-relay health"
    /// (the `ezvpn_conn_path` JSON). The reply is nil when no tunnel is running.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler else { return }
        guard messageData.count == 1 else {
            completionHandler(nil)
            return
        }
        switch messageData[0] {
        case 0:
            workQueue.async { [self] in
                guard
                    let runtimeConfig,
                    let data = try? JSONSerialization.data(withJSONObject: runtimeConfig)
                else {
                    completionHandler(nil)
                    return
                }
                completionHandler(data)
            }
        case 1:
            workQueue.async { [self] in
                guard let handle else {
                    completionHandler(nil)
                    return
                }
                var buf = [CChar](repeating: 0, count: 4096)
                guard ezvpn_conn_path(handle, &buf, buf.count) == 1 else {
                    completionHandler(nil)
                    return
                }
                completionHandler(Data(String(cString: buf).utf8))
            }
        default:
            completionHandler(nil)
        }
    }

    // MARK: - Helpers

    private static func error(_ message: String) -> NSError {
        NSError(domain: "ezvpn", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Routes implied by the interface assignment itself. The server advertises
    /// a host mask (/32), so there is no on-link subnet to route — only the
    /// gateway host route, which is what makes the server end of the tunnel
    /// reachable with no user-configured routes. A real subnet mask (host bits
    /// present) additionally routes that on-link subnet; a route to the assigned
    /// address itself is never emitted (routing your own address is a no-op).
    private static func ipv4InterfaceRoutes(
        ip: String, mask: String, gateway: String?
    ) -> [NEIPv4Route] {
        guard let ipBits = ipv4Bits(ip), let maskBits = ipv4Bits(mask) else { return [] }
        var routes: [NEIPv4Route] = []
        // Skip the on-link subnet route under a host mask (/32): it would just be
        // a route to our own address.
        if maskBits != ~UInt32(0) {
            routes.append(NEIPv4Route(
                destinationAddress: ipv4String(ipBits & maskBits), subnetMask: mask))
        }
        if let gateway, let gwBits = ipv4Bits(gateway), gwBits & maskBits != ipBits & maskBits {
            routes.append(NEIPv4Route(
                destinationAddress: gateway, subnetMask: "255.255.255.255"))
        }
        return routes
    }

    /// IPv6 mirror of `ipv4InterfaceRoutes`.
    private static func ipv6InterfaceRoutes(
        ip: String, prefix: Int, gateway: String?
    ) -> [NEIPv6Route] {
        guard let network = ipv6Network(ip, prefix: prefix) else { return [] }
        var routes: [NEIPv6Route] = []
        // Skip the on-link subnet route under a host mask (/128): it would just
        // be a route to our own address.
        if prefix < 128 {
            routes.append(NEIPv6Route(
                destinationAddress: network, networkPrefixLength: NSNumber(value: prefix)))
        }
        if let gateway, ipv6Network(gateway, prefix: prefix) != network {
            routes.append(NEIPv6Route(
                destinationAddress: gateway, networkPrefixLength: 128))
        }
        return routes
    }

    /// Render an installed route back to CIDR text for the debug UI.
    private static func cidrString(_ route: NEIPv4Route) -> String {
        let prefix = ipv4Bits(route.destinationSubnetMask)?.nonzeroBitCount ?? 32
        return "\(route.destinationAddress)/\(prefix)"
    }

    private static func cidrString(_ route: NEIPv6Route) -> String {
        "\(route.destinationAddress)/\(route.destinationNetworkPrefixLength)"
    }

    /// Convert "10.0.0.0/8" into an NEIPv4Route.
    private static func ipv4Route(_ cidr: String) -> NEIPv4Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...32).contains(prefix) else {
            return nil
        }
        return NEIPv4Route(destinationAddress: String(parts[0]), subnetMask: ipv4Mask(prefix))
    }

    /// Convert "fd00::/64" into an NEIPv6Route.
    private static func ipv6Route(_ cidr: String) -> NEIPv6Route? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefix = Int(parts[1]), (0...128).contains(prefix) else {
            return nil
        }
        return NEIPv6Route(
            destinationAddress: String(parts[0]), networkPrefixLength: NSNumber(value: prefix))
    }

    /// Locate the `utun` file descriptor the OS created for this tunnel.
    ///
    /// NetworkExtension does not hand the fd to us directly. On iOS and macOS,
    /// probe each open fd with the `UTUN_OPT_IFNAME` control-socket option and
    /// keep the one whose interface name starts with `utun`. The constants are
    /// hardcoded because the iOS SDK does not expose the required headers:
    ///   SYSPROTO_CONTROL = 2 (sys/sys_domain.h),
    ///   UTUN_OPT_IFNAME  = 2 (net/if_utun.h).
    private var tunnelFileDescriptor: Int32? {
        let sysprotoControl: Int32 = 2
        let utunOptIfname: Int32 = 2
        var nameBuf = [CChar](repeating: 0, count: 64)
        for fd: Int32 in 0...1024 {
            var len = socklen_t(nameBuf.count)
            let ret = getsockopt(fd, sysprotoControl, utunOptIfname, &nameBuf, &len)
            if ret == 0, String(cString: nameBuf).hasPrefix("utun") {
                return fd
            }
        }
        return nil
    }
}
