import Foundation
import Darwin

/// Minimal ICMP echo support using a SOCK_DGRAM/IPPROTO_ICMP socket, which iOS allows without
/// root (the kernel fills in the IP header and strips it on receive for IPv4).
enum ICMP {
    struct Reply { let seq: UInt16; let ttl: Int?; let bytes: Int; let from: String; let rtt: Double }

    static func resolve(_ host: String, family: Int32 = AF_UNSPEC) throws -> (addr: sockaddr_storage, len: socklen_t, ip: String) {
        var hints = addrinfo(); hints.ai_family = family; hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>? = nil
        let rc = getaddrinfo(host, nil, &hints, &res)
        guard rc == 0, let r = res else { throw CommandError("cannot resolve \(host): \(String(cString: gai_strerror(rc)))") }
        defer { freeaddrinfo(res) }
        var storage = sockaddr_storage()
        memcpy(&storage, r.pointee.ai_addr, Int(r.pointee.ai_addrlen))
        return (storage, r.pointee.ai_addrlen, ipString(r.pointee.ai_addr, r.pointee.ai_addrlen))
    }

    static func ipString(_ sa: UnsafePointer<sockaddr>, _ len: socklen_t) -> String {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        getnameinfo(sa, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
        return String(cString: buf)
    }

    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count { sum += UInt32(data[i]) << 8 | UInt32(data[i+1]); i += 2 }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum & 0xffff)
    }

    static func echoPacket(id: UInt16, seq: UInt16, size: Int, v6: Bool) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 8 + size)
        p[0] = v6 ? 128 : 8 // echo request
        p[4] = UInt8(id >> 8); p[5] = UInt8(id & 0xff)
        p[6] = UInt8(seq >> 8); p[7] = UInt8(seq & 0xff)
        for i in 0..<size { p[8 + i] = UInt8(truncatingIfNeeded: i) }
        if !v6 { let c = checksum(p); p[2] = UInt8(c >> 8); p[3] = UInt8(c & 0xff) }
        return p
    }

    /// Opens an ICMP datagram socket for the address family.
    static func openSocket(v6: Bool) throws -> Int32 {
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_DGRAM, v6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP)
        guard fd >= 0 else { throw CommandError("socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        if !v6 { setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &one, socklen_t(MemoryLayout<Int32>.size)) }
        return fd
    }

    /// Sends one echo request and waits for a reply with timeout. Returns nil on timeout.
    static func ping(fd: Int32, to addr: sockaddr_storage, len: socklen_t, id: UInt16, seq: UInt16, size: Int, timeout: Double, v6: Bool) -> Reply? {
        let pkt = echoPacket(id: id, seq: seq, size: size, v6: v6)
        var a = addr
        let start = Date()
        let sent = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, len) } }
        guard sent == pkt.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date().timeIntervalSince(start) < timeout {
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)
            var readSet = fd_set(); fdZero(&readSet); fdSet(fd, &readSet)
            let r = select(fd + 1, &readSet, nil, nil, &tv)
            if r <= 0 { continue }
            var from = sockaddr_storage(); var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            var iov = iovec(iov_base: &buf, iov_len: buf.count)
            var ctrl = [UInt8](repeating: 0, count: 64)
            var msg = msghdr()
            withUnsafeMutablePointer(to: &from) { fp in
                msg.msg_name = UnsafeMutableRawPointer(fp); msg.msg_namelen = fromLen
            }
            msg.msg_iov = withUnsafeMutablePointer(to: &iov) { $0 }; msg.msg_iovlen = 1
            ctrl.withUnsafeMutableBufferPointer { msg.msg_control = UnsafeMutableRawPointer($0.baseAddress); msg.msg_controllen = socklen_t($0.count) }
            let n = recvmsg(fd, &msg, 0)
            fromLen = msg.msg_namelen
            guard n > 0 else { continue }
            var ttl: Int? = nil
            // parse cmsg for TTL (IPv4)
            if msg.msg_controllen >= MemoryLayout<cmsghdr>.size {
                ctrl.withUnsafeBytes { raw in
                    let h = raw.load(as: cmsghdr.self)
                    if h.cmsg_level == IPPROTO_IP && h.cmsg_type == IP_RECVTTL && Int(h.cmsg_len) >= MemoryLayout<cmsghdr>.size + 1 { ttl = Int(raw[MemoryLayout<cmsghdr>.size]) }
                }
            }
            var off = 0
            if !v6 && n >= 20 && (buf[0] >> 4) == 4 { off = Int(buf[0] & 0x0f) * 4; ttl = Int(buf[8]) } // header included on some kernels
            guard n >= off + 8 else { continue }
            let type = buf[off]
            let rid = UInt16(buf[off+4]) << 8 | UInt16(buf[off+5]), rseq = UInt16(buf[off+6]) << 8 | UInt16(buf[off+7])
            let isReply = v6 ? type == 129 : type == 0
            // The kernel rewrites the id for unprivileged ICMP sockets, so match seq and accept the kernel's id.
            if isReply && rseq == seq || (isReply && rid == id) {
                let ip = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ipString($0, fromLen) } }
                return Reply(seq: rseq, ttl: ttl, bytes: Int(n) - off, from: ip, rtt: Date().timeIntervalSince(start) * 1000)
            }
        }
        return nil
    }

    // fd_set helpers
    static func fdZero(_ set: inout fd_set) { set = fd_set() }
    static func fdSet(_ fd: Int32, _ set: inout fd_set) {
        let intOffset = Int(fd) / 32, bitOffset = Int(fd) % 32
        withUnsafeMutablePointer(to: &set.fds_bits) { p in
            p.withMemoryRebound(to: Int32.self, capacity: 32) { $0[intOffset] |= Int32(bitPattern: UInt32(1) << UInt32(bitOffset)) }
        }
    }
}
