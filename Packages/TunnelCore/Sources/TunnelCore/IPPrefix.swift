import Darwin

/// Parse a dotted quad into its 32-bit value.
public func ipv4Bits(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".")
    guard parts.count == 4 else { return nil }
    var value: UInt32 = 0
    for part in parts {
        guard let byte = UInt8(part) else { return nil }
        value = (value << 8) | UInt32(byte)
    }
    return value
}

/// Render a 32-bit value back to a dotted quad.
public func ipv4String(_ bits: UInt32) -> String {
    "\((bits >> 24) & 0xff).\((bits >> 16) & 0xff).\((bits >> 8) & 0xff).\(bits & 0xff)"
}

/// Dotted-quad netmask for a prefix length (24 → "255.255.255.0").
public func ipv4Mask(_ prefix: Int) -> String {
    let m: UInt32 = prefix == 0 ? 0 : (~UInt32(0) << (32 - prefix))
    return ipv4String(m)
}

/// The network address of `ip` under `prefix` (host bits zeroed), or nil if
/// `ip` doesn't parse.
public func ipv6Network(_ ip: String, prefix: Int) -> String? {
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

/// Parse "10.0.0.0/8" or "fd00::/8" into address bytes + prefix length.
public func parseCIDR(_ cidr: String, family: Int32) -> (bytes: [UInt8], prefix: Int)? {
    let parts = cidr.split(separator: "/")
    let maxPrefix = family == AF_INET ? 32 : 128
    guard parts.count == 2, let prefix = Int(parts[1]),
          (0...maxPrefix).contains(prefix)
    else { return nil }
    if family == AF_INET {
        var addr = in_addr()
        guard inet_pton(AF_INET, String(parts[0]), &addr) == 1 else { return nil }
        return (withUnsafeBytes(of: addr) { Array($0) }, prefix)
    } else {
        var addr = in6_addr()
        guard inet_pton(AF_INET6, String(parts[0]), &addr) == 1 else { return nil }
        return (withUnsafeBytes(of: addr) { Array($0) }, prefix)
    }
}

/// Two prefixes overlap iff they agree on the first min(prefix) bits — works
/// on network-order bytes, so IPv4 and IPv6 share the one routine.
public func prefixesOverlap(
    _ a: [UInt8], _ aPrefix: Int, _ b: [UInt8], _ bPrefix: Int
) -> Bool {
    var bits = min(aPrefix, bPrefix)
    var i = 0
    while bits >= 8 {
        if a[i] != b[i] { return false }
        i += 1
        bits -= 8
    }
    if bits > 0 {
        let mask = UInt8(truncatingIfNeeded: 0xff << (8 - bits))
        return a[i] & mask == b[i] & mask
    }
    return true
}

/// Prefix length implied by a netmask's leading one-bits.
public func leadingOnes(_ mask: [UInt8]) -> Int {
    var count = 0
    for byte in mask {
        if byte == 0xff { count += 8; continue }
        var b = byte
        while b & 0x80 != 0 { count += 1; b <<= 1 }
        break
    }
    return count
}

/// Render address bytes + prefix as CIDR text with host bits zeroed
/// (e.g. 192.168.1.23 under /24 → "192.168.1.0/24").
public func cidrDescription(_ bytes: [UInt8], _ prefix: Int) -> String {
    var masked = bytes
    for i in 0..<masked.count {
        let bitStart = i * 8
        if bitStart >= prefix {
            masked[i] = 0
        } else if bitStart + 8 > prefix {
            masked[i] &= UInt8(truncatingIfNeeded: 0xff << (8 - (prefix - bitStart)))
        }
    }
    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    let family: Int32 = masked.count == 4 ? AF_INET : AF_INET6
    let rendered = masked.withUnsafeBytes { raw in
        inet_ntop(family, raw.baseAddress, &buf, socklen_t(buf.count)) != nil
    }
    return rendered ? "\(String(cString: buf))/\(prefix)" : "?/\(prefix)"
}
