import Darwin

/// One network the device is attached to: the on-link subnet of an up,
/// running, non-loopback interface. Point-to-point links (cellular) carry no
/// on-link subnet to conflict with and are skipped by `localNetworks()`.
public struct LocalNetwork {
    /// Interface name (e.g. "en0"), for the refusal message.
    public let interface: String
    /// Address bytes in network order: 4 (IPv4) or 16 (IPv6).
    public let bytes: [UInt8]
    public let prefix: Int

    public init(interface: String, bytes: [UInt8], prefix: Int) {
        self.interface = interface
        self.bytes = bytes
        self.prefix = prefix
    }
}

/// Enumerate the on-link networks of every active broadcast interface via
/// getifaddrs. Loopback, point-to-point, utun, and IPv6 link-local entries are
/// excluded: none of them describe a routable local subnet.
public func localNetworks() -> [LocalNetwork] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    var list: [LocalNetwork] = []
    for ifa in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(bitPattern: ifa.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
              flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
              let sa = ifa.pointee.ifa_addr, let sm = ifa.pointee.ifa_netmask
        else { continue }
        let name = String(cString: ifa.pointee.ifa_name)
        guard !name.hasPrefix("utun") else { continue }

        switch Int32(sa.pointee.sa_family) {
        case AF_INET:
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
            let mask = sm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) }
            }
            list.append(LocalNetwork(interface: name, bytes: addr, prefix: leadingOnes(mask)))
        case AF_INET6:
            let addr = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            // Link-local lives on every interface and never routes.
            if addr[0] == 0xfe, addr[1] & 0xc0 == 0x80 { continue }
            let mask = sm.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
            }
            list.append(LocalNetwork(interface: name, bytes: addr, prefix: leadingOnes(mask)))
        default:
            continue
        }
    }
    return list
}

/// The first configured split-tunnel prefix that overlaps a network the
/// device is currently on, rendered as a refusal message; nil when clear.
/// Malformed CIDRs are skipped here — the caller drops them from the applied
/// route set anyway. `localNetworks` defaults to the live interface list; it
/// is a parameter so the logic is testable with a fixed fixture.
public func splitTunnelConflict(
    routes: [String],
    routes6: [String],
    localNetworks locals: [LocalNetwork] = localNetworks()
) -> String? {
    for (cidrs, family) in [(routes, AF_INET), (routes6, AF_INET6)] {
        let byteCount = family == AF_INET ? 4 : 16
        for cidr in cidrs {
            guard let (bytes, prefix) = parseCIDR(cidr, family: family) else { continue }
            for local in locals where local.bytes.count == byteCount {
                if prefixesOverlap(bytes, prefix, local.bytes, local.prefix) {
                    return "refusing to start: split-tunnel route \(cidr) overlaps "
                        + "current network \(cidrDescription(local.bytes, local.prefix)) "
                        + "on \(local.interface)"
                }
            }
        }
    }
    return nil
}
