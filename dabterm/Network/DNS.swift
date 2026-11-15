import Foundation
import Darwin

/// A tiny DNS client: builds a query, sends it over UDP (system resolver or a given server)
/// and parses the answer section. Enough for dig-style lookups of common record types.
enum DNS {
    struct Answer { let name: String; let type: String; let ttl: UInt32; let data: String }
    static let types: [String: UInt16] = ["A": 1, "NS": 2, "CNAME": 5, "SOA": 6, "PTR": 12, "MX": 15, "TXT": 16, "AAAA": 28, "SRV": 33, "CAA": 257, "ANY": 255]

    /// iOS exposes no public API for the active resolver list (libresolv's res_9_* entry points
    /// are macOS-only), so queries without @server go to public resolvers. Use `dig @192.168.1.1`
    /// for a LAN resolver, or `host` which uses the system resolver via getaddrinfo.
    static func systemServers() -> [String] { ["1.1.1.1", "8.8.8.8"] }

    static func query(name: String, type: String, server: String?) async throws -> [Answer] {
        guard let qtype = types[type] else { throw CommandError("unsupported record type \(type)") }
        var qname = name
        if qtype == 12, !name.hasSuffix(".arpa") { qname = reverseName(name) }
        let servers = server.map { [$0] } ?? systemServers()
        var lastError: Error = CommandError("no response")
        for s in servers {
            do { return try await Task.detached { try send(qname: qname, qtype: qtype, server: s) }.value }
            catch { lastError = error }
        }
        throw lastError
    }

    static func reverseName(_ ip: String) -> String {
        if ip.contains(":") {
            var a = in6_addr(); inet_pton(AF_INET6, ip, &a)
            let bytes = withUnsafeBytes(of: &a) { Array($0) }
            return bytes.reversed().flatMap { [String(format: "%x", $0 & 0xf), String(format: "%x", $0 >> 4)] }.joined(separator: ".") + ".ip6.arpa"
        }
        return ip.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa"
    }

    private static func send(qname: String, qtype: UInt16, server: String) throws -> [Answer] {
        var pkt: [UInt8] = []
        let id = UInt16.random(in: 1...65000)
        pkt += [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in qname.split(separator: ".") { pkt.append(UInt8(label.utf8.count)); pkt += Array(label.utf8) }
        pkt += [0, UInt8(qtype >> 8), UInt8(qtype & 0xff), 0, 1]
        let target = try ICMP.resolve(server)
        let fd = socket(Int32(target.addr.ss_family), SOCK_DGRAM, 0)
        guard fd >= 0 else { throw CommandError("socket failed") }
        defer { close(fd) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = target.addr
        if addr.ss_family == UInt8(AF_INET) { withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_port = UInt16(53).bigEndian } } }
        else { withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_port = UInt16(53).bigEndian } } }
        let sent = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, target.len) } }
        guard sent == pkt.count else { throw CommandError("send failed to \(server)") }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 12 else { throw CommandError("no response from \(server)") }
        let resp = Array(buf[0..<Int(n)])
        guard UInt16(resp[0]) << 8 | UInt16(resp[1]) == id else { throw CommandError("mismatched response id") }
        let rcode = resp[3] & 0x0f
        if rcode == 3 { throw CommandError("NXDOMAIN: \(qname) does not exist") }
        if rcode != 0 { throw CommandError("server returned rcode \(rcode)") }
        let qd = Int(UInt16(resp[4]) << 8 | UInt16(resp[5])), an = Int(UInt16(resp[6]) << 8 | UInt16(resp[7]))
        var off = 12
        for _ in 0..<qd { _ = readName(resp, &off); off += 4 }
        var answers: [Answer] = []
        for _ in 0..<an {
            let nm = readName(resp, &off)
            guard off + 10 <= resp.count else { break }
            let t = UInt16(resp[off]) << 8 | UInt16(resp[off+1])
            let ttl = UInt32(resp[off+4]) << 24 | UInt32(resp[off+5]) << 16 | UInt32(resp[off+6]) << 8 | UInt32(resp[off+7])
            let rdlen = Int(UInt16(resp[off+8]) << 8 | UInt16(resp[off+9]))
            off += 10
            let rdStart = off
            var data = ""
            switch t {
            case 1: data = resp[off..<off+4].map(String.init).joined(separator: ".")
            case 28: var a = in6_addr(); memcpy(&a, Array(resp[off..<off+16]), 16); var s = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN)); inet_ntop(AF_INET6, &a, &s, socklen_t(s.count)); data = String(cString: s)
            case 2, 5, 12: var o = off; data = readName(resp, &o) + "."
            case 15: let pref = UInt16(resp[off]) << 8 | UInt16(resp[off+1]); var o = off + 2; data = "\(pref) \(readName(resp, &o))."
            case 16:
                var o = off; var parts: [String] = []
                while o < rdStart + rdlen { let l = Int(resp[o]); o += 1; parts.append("\"" + String(decoding: resp[o..<min(o+l, resp.count)], as: UTF8.self) + "\""); o += l }
                data = parts.joined(separator: " ")
            case 33: let pri = UInt16(resp[off]) << 8 | UInt16(resp[off+1]), w = UInt16(resp[off+2]) << 8 | UInt16(resp[off+3]), port = UInt16(resp[off+4]) << 8 | UInt16(resp[off+5]); var o = off + 6; data = "\(pri) \(w) \(port) \(readName(resp, &o))."
            case 6: var o = off; let m = readName(resp, &o); let r = readName(resp, &o); let serial = UInt32(resp[o]) << 24 | UInt32(resp[o+1]) << 16 | UInt32(resp[o+2]) << 8 | UInt32(resp[o+3]); data = "\(m). \(r). \(serial)"
            case 257: let flags = resp[off]; let tl = Int(resp[off+1]); let tag = String(decoding: resp[off+2..<off+2+tl], as: UTF8.self); data = "\(flags) \(tag) \"\(String(decoding: resp[off+2+tl..<rdStart+rdlen], as: UTF8.self))\""
            default: data = resp[off..<rdStart+rdlen].map { String(format: "%02x", $0) }.joined()
            }
            off = rdStart + rdlen
            let typeName = types.first { $0.value == t }?.key ?? "TYPE\(t)"
            answers.append(Answer(name: nm + ".", type: typeName, ttl: ttl, data: data))
        }
        return answers
    }

    private static func readName(_ b: [UInt8], _ off: inout Int) -> String {
        var labels: [String] = []
        var o = off; var jumped = false; var guardCount = 0
        while o < b.count, guardCount < 64 {
            guardCount += 1
            let l = Int(b[o])
            if l == 0 { o += 1; break }
            if l & 0xC0 == 0xC0 { let ptr = Int(UInt16(b[o] & 0x3f) << 8 | UInt16(b[o+1])); if !jumped { off = o + 2 }; jumped = true; o = ptr; continue }
            o += 1
            labels.append(String(decoding: b[o..<min(o+l, b.count)], as: UTF8.self)); o += l
        }
        if !jumped { off = o }
        return labels.joined(separator: ".")
    }
}
