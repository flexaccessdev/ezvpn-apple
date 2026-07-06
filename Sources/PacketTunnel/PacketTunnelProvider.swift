import NetworkExtension
import Darwin
import os.log

/// The Packet Tunnel Provider: the process the OS runs to carry VPN traffic.
///
/// It bridges iOS's `NEPacketTunnelProvider` to the Rust core (libezvpn.a):
/// configure the tunnel interface from the server's handshake, hand the `utun`
/// fd to Rust, and let Rust run the iroh/QUIC datagram loop.
class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = OSLog(subsystem: "com.example.ezvpn.PacketTunnel", category: "tunnel")
    private var handle: OpaquePointer?

    /// Serializes backend teardown and runtime-config queries, mirroring
    /// WireGuardAdapter's private work queue: `stopTunnel` completes only
    /// after `ezvpn_stop` has actually returned, and never blocks the
    /// provider's calling queue while the Rust side shuts down.
    private let workQueue = DispatchQueue(label: "com.example.ezvpn.PacketTunnel.workQueue")

    /// What was actually applied to the interface (assigned addresses, tunnel
    /// routes, bypass routes, MTU), kept so the app can query it over
    /// `handleAppMessage` — the same runtime-configuration mechanism the
    /// WireGuard app uses. Accessed on `workQueue` only.
    private var runtimeConfig: [String: Any]?

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
        let authToken = conf["auth_token"] as? String
        let relayURLs = conf["relay_urls"] as? [String] ?? []
        let routes = conf["routes"] as? [String] ?? []
        let routes6 = conf["routes6"] as? [String] ?? []

        // Build the FFI config JSON. routes/routes6 are forwarded so the core can
        // compute which server underlay addresses overlap and must be excluded.
        let configDict: [String: Any] = [
            "server_node_id": serverNodeID,
            "auth_token": (authToken?.isEmpty == false) ? authToken! : NSNull(),
            "relay_urls": relayURLs,
            "relay_only": false,
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
        // `handle` is stored into `self.handle` only once all synchronous
        // validation below has passed (just before setTunnelNetworkSettings), so
        // these pre-flight error paths only need to stop the local handle. All
        // access to `self.handle` is confined to `workQueue`, mirroring
        // `runtimeConfig`, so stopTunnel and the async completion below can never
        // race into a double `ezvpn_stop` (which would double-free the handle).
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

        // User route lists are optional: the tunnel's own subnet (derived from the
        // assigned address + mask) is always routed, so the server side of the
        // tunnel (e.g. 10.124.0.1) is reachable with no configuration. Extra
        // routes widen the split tunnel. Routes for a family the server did not
        // assign can't be applied — warn so it isn't silently ignored.
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

        // Publish the handle so stopTunnel can find it, then keep every further
        // touch of it on workQueue. Enqueued before the completion's own
        // workQueue block, so the serial queue guarantees the store lands first.
        workQueue.async { self.handle = handle }

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
                completionHandler(nil)
            }
        }
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
    /// a single byte 0 means "get runtime configuration"; the reply is the
    /// applied network config as JSON, nil when no tunnel is running.
    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler else { return }
        guard messageData.count == 1, messageData[0] == 0 else {
            completionHandler(nil)
            return
        }
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
    }

    // MARK: - Helpers

    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.example.ezvpn", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Routes implied by the interface assignment itself: the on-link subnet of
    /// the assigned address (so the server end of the tunnel is reachable with
    /// no user-configured routes), plus a host route to the gateway for the
    /// point-to-point case where the gateway sits outside that subnet.
    private static func ipv4InterfaceRoutes(
        ip: String, mask: String, gateway: String?
    ) -> [NEIPv4Route] {
        guard let ipBits = ipv4Bits(ip), let maskBits = ipv4Bits(mask) else { return [] }
        var routes = [NEIPv4Route(
            destinationAddress: ipv4String(ipBits & maskBits), subnetMask: mask)]
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
        var routes = [NEIPv6Route(
            destinationAddress: network, networkPrefixLength: NSNumber(value: prefix))]
        if let gateway, ipv6Network(gateway, prefix: prefix) != network {
            routes.append(NEIPv6Route(
                destinationAddress: gateway, networkPrefixLength: 128))
        }
        return routes
    }

    /// Parse a dotted quad into its 32-bit value.
    private static func ipv4Bits(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".")
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let byte = UInt8(part) else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    private static func ipv4String(_ bits: UInt32) -> String {
        "\((bits >> 24) & 0xff).\((bits >> 16) & 0xff).\((bits >> 8) & 0xff).\(bits & 0xff)"
    }

    /// The network address of `ip` under `prefix` (host bits zeroed), or nil if
    /// `ip` doesn't parse.
    private static func ipv6Network(_ ip: String, prefix: Int) -> String? {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, ip, &addr) == 1 else { return nil }
        withUnsafeMutableBytes(of: &addr) { raw in
            for i in 0..<16 {
                let bitStart = i * 8
                if bitStart >= prefix {
                    raw[i] = 0
                } else if bitStart + 8 > prefix {
                    raw[i] &= UInt8(truncatingIfNeeded: 0xff << (8 - (prefix - bitStart)))
                }
            }
        }
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count)) != nil else { return nil }
        return String(cString: buf)
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

    private static func ipv4Mask(_ prefix: Int) -> String {
        let m: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
        return "\((m >> 24) & 0xff).\((m >> 16) & 0xff).\((m >> 8) & 0xff).\(m & 0xff)"
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
    /// NetworkExtension does not hand the fd to us directly. The iOS SDK omits
    /// `<sys/kern_control.h>`, so we use the portable technique: probe each open
    /// fd with the `UTUN_OPT_IFNAME` control-socket option and keep the one
    /// whose interface name starts with `utun`. The constants are hardcoded
    /// because their headers are unavailable on iOS:
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
