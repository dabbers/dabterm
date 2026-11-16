import Foundation
import Darwin
import Network

struct PingCommand: Command {
    let name = "ping"; let usage = "ping [-c count] [-i interval] [-s size] [-6] host"; let summary = "ICMP echo"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["c", "i", "s", "W"])
        guard let host = pos.first else { throw CommandError("usage: \(usage)") }
        let count = Int(flags["c"] ?? "") ?? (ctx.out is TerminalSink ? Int.max : 4)
        let interval = Double(flags["i"] ?? "1") ?? 1
        let size = Int(flags["s"] ?? "56") ?? 56
        let timeout = Double(flags["W"] ?? "2") ?? 2
        let v6 = flags["6"] != nil
        let target = try ICMP.resolve(host, family: v6 ? AF_INET6 : (flags["4"] != nil ? AF_INET : AF_UNSPEC))
        let isV6 = target.addr.ss_family == UInt8(AF_INET6)
        let fd = try ICMP.openSocket(v6: isV6)
        defer { close(fd) }
        ctx.print("PING \(host) (\(target.ip)): \(size) data bytes")
        let id = UInt16(truncatingIfNeeded: getpid())
        var sent = 0, recv = 0; var rtts: [Double] = []
        var seq: UInt16 = 0
        let start = Date()
        while sent < count {
            if Task.isCancelled { break }
            let t = target
            let reply = await Task.detached(priority: .userInitiated) { ICMP.ping(fd: fd, to: t.addr, len: t.len, id: id, seq: seq, size: size, timeout: timeout, v6: isV6) }.value
            sent += 1
            if let r = reply {
                recv += 1; rtts.append(r.rtt)
                ctx.print("\(r.bytes) bytes from \(r.from): icmp_seq=\(r.seq)\(r.ttl.map { " ttl=\($0)" } ?? "") time=\(String(format: "%.3f", r.rtt)) ms")
            } else { ctx.print("Request timeout for icmp_seq \(seq)") }
            seq &+= 1
            if sent < count {
                do { try await Task.sleep(nanoseconds: UInt64(max(0.2, interval) * 1_000_000_000)) } catch { break }
            }
        }
        let loss = sent == 0 ? 0 : Double(sent - recv) / Double(sent) * 100
        ctx.print("\n--- \(host) ping statistics ---\n\(sent) packets transmitted, \(recv) packets received, \(String(format: "%.1f", loss))% packet loss, time \(Int(Date().timeIntervalSince(start) * 1000))ms")
        if !rtts.isEmpty {
            let avg = rtts.reduce(0, +) / Double(rtts.count)
            let sd = (rtts.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(rtts.count)).squareRoot()
            ctx.print("round-trip min/avg/max/stddev = \(String(format: "%.3f/%.3f/%.3f/%.3f", rtts.min()!, avg, rtts.max()!, sd)) ms")
        }
        return recv > 0 ? 0 : 1
    }
}

struct TracerouteCommand: Command {
    let name = "traceroute"; let usage = "traceroute [-m maxhops] [-q probes] [-w wait] host"; let summary = "trace the route to a host (ICMP)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["m", "q", "w"])
        guard let host = pos.first else { throw CommandError("usage: \(usage)") }
        let maxHops = Int(flags["m"] ?? "30") ?? 30, probes = Int(flags["q"] ?? "3") ?? 3, wait = Double(flags["w"] ?? "2") ?? 2
        let target = try ICMP.resolve(host, family: AF_INET)
        ctx.print("traceroute to \(host) (\(target.ip)), \(maxHops) hops max, 60 byte packets")
        let fd = try ICMP.openSocket(v6: false)
        defer { close(fd) }
        let id = UInt16(truncatingIfNeeded: getpid())
        var seq: UInt16 = 1
        for ttl in 1...maxHops {
            if Task.isCancelled { return 130 }
            var t = Int32(ttl)
            setsockopt(fd, IPPROTO_IP, IP_TTL, &t, socklen_t(MemoryLayout<Int32>.size))
            var line = String(format: "%2d  ", ttl)
            var hopAddr: String? = nil
            var reached = false
            for _ in 0..<probes {
                let s = seq; seq &+= 1
                let tgt = target
                let result = await Task.detached(priority: .userInitiated) { Traceroute.probe(fd: fd, to: tgt.addr, len: tgt.len, id: id, seq: s, timeout: wait) }.value
                switch result {
                case .none: line += "* "
                case .some(let r):
                    if hopAddr != r.from { hopAddr = r.from; line += "\(r.host ?? r.from) (\(r.from))  " }
                    line += String(format: "%.3f ms  ", r.rtt)
                    if r.reached { reached = true }
                }
            }
            ctx.print(line)
            if reached { break }
        }
        return 0
    }
}

enum Traceroute {
    struct Hop { let from: String; let host: String?; let rtt: Double; let reached: Bool }
    /// Sends an ICMP echo with the socket's current TTL; a time-exceeded message from a router
    /// (type 11) or an echo reply (type 0) are both delivered to the ICMP datagram socket.
    static func probe(fd: Int32, to addr: sockaddr_storage, len: socklen_t, id: UInt16, seq: UInt16, timeout: Double) -> Hop? {
        let pkt = ICMP.echoPacket(id: id, seq: seq, size: 32, v6: false)
        var a = addr
        let start = Date()
        _ = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, len) } }
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date().timeIntervalSince(start) < timeout {
            var tv = timeval(tv_sec: 0, tv_usec: 200_000)
            var set = fd_set(); ICMP.fdSet(fd, &set)
            if select(fd + 1, &set, nil, nil, &tv) <= 0 { continue }
            var from = sockaddr_storage(); var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &fromLen) } }
            guard n >= 8 else { continue }
            var off = 0
            if n >= 20 && (buf[0] >> 4) == 4 { off = Int(buf[0] & 0x0f) * 4 }
            let type = buf[off]
            let ip = withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ICMP.ipString($0, fromLen) } }
            if type == 0 {
                let rseq = UInt16(buf[off+6]) << 8 | UInt16(buf[off+7])
                if rseq == seq { return Hop(from: ip, host: reverse(ip), rtt: Date().timeIntervalSince(start) * 1000, reached: true) }
            } else if type == 11 || type == 3 {
                // inner IP header starts at off+8, inner ICMP header after it
                let innerIP = off + 8
                guard n > innerIP + 20 + 8 else { continue }
                let ihl = Int(buf[innerIP] & 0x0f) * 4
                let inner = innerIP + ihl
                let rseq = UInt16(buf[inner+6]) << 8 | UInt16(buf[inner+7])
                if rseq == seq { return Hop(from: ip, host: reverse(ip), rtt: Date().timeIntervalSince(start) * 1000, reached: type == 3) }
            }
        }
        return nil
    }
    static func reverse(_ ip: String) -> String? {
        var hints = addrinfo(); hints.ai_flags = AI_NUMERICHOST
        var res: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(ip, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(r.pointee.ai_addr, r.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NAMEREQD) == 0 else { return nil }
        return String(cString: buf)
    }
}

struct DigCommand: Command {
    let name = "dig"; let usage = "dig [@server] name [A|AAAA|MX|TXT|NS|CNAME|SRV|PTR] [+short]"; let summary = "DNS lookup"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var args = ctx.args
        var server: String? = nil
        if let s = args.first(where: { $0.hasPrefix("@") }) { server = String(s.dropFirst()); args.removeAll { $0 == s } }
        let short = args.contains("+short"); args.removeAll { $0.hasPrefix("+") }
        guard let qname = args.first else { throw CommandError("usage: \(usage)") }
        let type = args.count > 1 ? args[1].uppercased() : "A"
        let start = Date()
        let answers = try await DNS.query(name: qname, type: type, server: server)
        if short { for a in answers { ctx.print(a.data) }; return answers.isEmpty ? 1 : 0 }
        ctx.print("; <<>> dabterm dig <<>> \(qname) \(type)\(server.map { " @\($0)" } ?? "")\n;; QUESTION SECTION:\n;\(qname).\t\t\tIN\t\(type)\n")
        ctx.print(";; ANSWER SECTION:")
        for a in answers { ctx.print("\(a.name.padding(toLength: 24, withPad: " ", startingAt: 0))\t\(a.ttl)\tIN\t\(a.type)\t\(a.data)") }
        ctx.print("\n;; Query time: \(Int(Date().timeIntervalSince(start) * 1000)) msec\n;; SERVER: \(server ?? "1.1.1.1 (public; use @server for LAN)")\n;; WHEN: \(Date())")
        return answers.isEmpty ? 1 : 0
    }
}

struct HostCommand: Command {
    let name = "host"; let usage = "host name|ip"; let summary = "simple DNS lookup / reverse lookup"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let q = ctx.args.first else { throw CommandError("usage: \(usage)") }
        if let _ = IPv4Address(q) ?? nil, let r = Traceroute.reverse(q) { ctx.print("\(q) domain name pointer \(r)."); return 0 }
        if IPv6Address(q) != nil, let r = Traceroute.reverse(q) { ctx.print("\(q) domain name pointer \(r)."); return 0 }
        let a = try await DNS.query(name: q, type: "A", server: nil) + (try await DNS.query(name: q, type: "AAAA", server: nil))
        let mx = try? await DNS.query(name: q, type: "MX", server: nil)
        for r in a { ctx.print("\(q) has \(r.type == "AAAA" ? "IPv6 " : "")address \(r.data)") }
        for m in mx ?? [] { ctx.print("\(q) mail is handled by \(m.data)") }
        return a.isEmpty ? 1 : 0
    }
}

struct CurlCommand: Command {
    let name = "curl"; let usage = "curl [-X METHOD] [-H 'K: V'] [-d body] [-o file] [-i] [-s] [-L] [-k] url"; let summary = "HTTP client"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        // expand combined short flags: -sI -> -s -I, -kL -> -k -L, -XPOST -> -X POST
        var args: [String] = []
        let valueFlags: Set<Character> = ["X", "H", "d", "o", "u", "A", "m"]
        for a in ctx.args {
            if a.hasPrefix("-"), !a.hasPrefix("--"), a.count > 2 {
                var rest = Array(a.dropFirst())
                while let c = rest.first {
                    rest.removeFirst()
                    args.append("-" + String(c))
                    if valueFlags.contains(c), !rest.isEmpty { args.append(String(rest)); rest = [] }
                }
            } else { args.append(a) }
        }
        var method = "GET", headers: [String: String] = [:], body: String? = nil, out: String? = nil, includeHeaders = false, headOnly = false, insecure = false, verbose = false, user: String? = nil
        var url: String? = nil
        var i = 0
        while i < args.count {
            let a = args[i]
            func val() throws -> String { i += 1; guard i < args.count else { throw CommandError("missing value for \(a)") }; return args[i] }
            switch a {
            case "-X", "--request": method = try val()
            case "-H", "--header": let h = try val(); if let c = h.firstIndex(of: ":") { headers[String(h[..<c]).trimmingCharacters(in: .whitespaces)] = String(h[h.index(after: c)...]).trimmingCharacters(in: .whitespaces) }
            case "-d", "--data", "--data-raw", "--data-binary": body = try val(); if method == "GET" { method = "POST" }; if headers["Content-Type"] == nil { headers["Content-Type"] = "application/x-www-form-urlencoded" }
            case "--json": body = try val(); if method == "GET" { method = "POST" }; headers["Content-Type"] = "application/json"; headers["Accept"] = "application/json"
            case "-o", "--output": out = try val()
            case "-O": out = "" // use remote name
            case "-i", "--include": includeHeaders = true
            case "-I", "--head": headOnly = true; method = "HEAD"
            case "-s", "--silent", "-S", "-L", "--location", "--compressed": break
            case "-k", "--insecure": insecure = true
            case "-v", "--verbose": verbose = true
            case "-u", "--user": user = try val()
            case "-A", "--user-agent": headers["User-Agent"] = try val()
            case "-m", "--max-time", "--connect-timeout": _ = try val()
            default: if a.hasPrefix("-") { throw CommandError("unknown option \(a)") } else { url = a }
            }
            i += 1
        }
        guard var u = url else { throw CommandError("usage: \(usage)") }
        if !u.contains("://") { u = "http://" + u }
        guard let reqURL = URL(string: u) else { throw CommandError("bad url") }
        var req = URLRequest(url: reqURL); req.httpMethod = method
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if headers["User-Agent"] == nil { req.setValue("dabterm-curl/0.1", forHTTPHeaderField: "User-Agent") }
        if let user { req.setValue("Basic " + Data(user.utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        if let b = body { req.httpBody = b.hasPrefix("@") ? FileManager.default.contents(atPath: ctx.path(String(b.dropFirst())).path) : Data(b.utf8) }
        if verbose { ctx.printErr("> \(method) \(reqURL.path.isEmpty ? "/" : reqURL.path) HTTP/1.1\n> Host: \(reqURL.host ?? "")"); for (k, v) in headers { ctx.printErr("> \(k): \(v)") } }
        let session = insecure ? URLSession(configuration: .ephemeral, delegate: InsecureDelegate(), delegateQueue: nil) : URLSession.shared
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw CommandError("no HTTP response") }
        if includeHeaders || headOnly || verbose {
            let p = verbose ? "< " : ""
            ctx.print("\(p)HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
            for (k, v) in http.allHeaderFields { ctx.print("\(p)\(k): \(v)") }
            ctx.print("")
        }
        if headOnly { return 0 }
        if let o = out {
            let name = o.isEmpty ? (reqURL.lastPathComponent.isEmpty ? "index.html" : reqURL.lastPathComponent) : o
            try data.write(to: ctx.path(name))
            ctx.printErr("saved \(Formatter.bytes(Int64(data.count))) to \(name)")
        } else {
            let s = String(decoding: data, as: UTF8.self)
            ctx.out.write(s); if !s.hasSuffix("\n") && ctx.out is TerminalSink { ctx.out.write("\n") }
        }
        return http.statusCode >= 400 ? 22 : 0
    }
}

final class InsecureDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let t = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: t)) } else { completionHandler(.performDefaultHandling, nil) }
    }
}

struct WgetCommand: Command {
    let name = "wget"; let usage = "wget [-O file] url"; let summary = "download a file"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["O"])
        guard let u = pos.first else { throw CommandError("usage: \(usage)") }
        return try await CurlCommand().run(await ctx.derived(name: "curl", args: ["-o", flags["O"] ?? "", "-L", u]))
    }
}

struct HttpCommand: Command {
    let name = "http"; let usage = "http [METHOD] url [key=value ...] [Header:Value ...]"; let summary = "httpie-style JSON requests"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var args = ctx.args
        var method = "GET"
        if let f = args.first, ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"].contains(f.uppercased()) { method = f.uppercased(); args.removeFirst() }
        guard let u = args.first else { throw CommandError("usage: \(usage)") }
        var json: [String: Any] = [:]; var curlArgs = ["-X", method, "-i"]
        for a in args.dropFirst() {
            if let r = a.range(of: ":="), !a.contains("=") || a.range(of: "=")!.lowerBound > r.lowerBound { json[String(a[..<r.lowerBound])] = (try? JSONSerialization.jsonObject(with: Data(a[r.upperBound...].utf8), options: .fragmentsAllowed)) ?? a }
            else if let eq = a.firstIndex(of: "="), !a.contains(":") || a.firstIndex(of: ":")! > eq { json[String(a[..<eq])] = String(a[a.index(after: eq)...]) }
            else if a.contains(":") { curlArgs += ["-H", a] }
        }
        if !json.isEmpty { if method == "GET" { curlArgs[1] = "POST" }; curlArgs += ["--json", String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)] }
        curlArgs.append(u)
        return try await CurlCommand().run(await ctx.derived(name: "curl", args: curlArgs))
    }
}

struct NcCommand: Command {
    let name = "nc"; let usage = "nc [-z] [-u] [-w secs] host port"; let summary = "TCP/UDP connect, send stdin, print reply"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["w"])
        guard pos.count == 2, let port = UInt16(pos[1]) else { throw CommandError("usage: \(usage)") }
        let host = pos[0], zero = flags["z"] != nil, udp = flags["u"] != nil
        let timeout = Double(flags["w"] ?? "5") ?? 5
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: udp ? .udp : .tcp)
        let ok = try await withTimeout(timeout) { try await conn.ready() }
        if !ok { conn.cancel(); ctx.printErr("nc: connect to \(host) port \(port) timed out"); return 1 }
        if zero { ctx.print("Connection to \(host) port \(port) [\(udp ? "udp" : "tcp")] succeeded!"); conn.cancel(); return 0 }
        if let s = ctx.stdin, !s.isEmpty { try await conn.sendAsync(Data(s.utf8)) }
        else if ctx.out is TerminalSink, let input = ctx.acquireRawInput() {
            // interactive: forward keystrokes until Ctrl-C or Ctrl-D
            let reader = Task { while let d = try? await conn.receiveAsync() { ctx.out.write(String(decoding: d, as: UTF8.self)) } }
            for await bytes in input {
                if bytes.contains(3) || bytes.contains(4) { break }
                let text = String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\r", with: "\n")
                ctx.out.write(text == "\n" ? "\r\n" : text)
                try await conn.sendAsync(Data(text.utf8))
            }
            reader.cancel(); conn.cancel(); return 0
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Task.isCancelled {
            guard let d = try await withTimeoutValue(min(timeout, 2), { try await conn.receiveAsync() }) ?? nil else { break }
            ctx.out.write(String(decoding: d, as: UTF8.self))
        }
        conn.cancel()
        return 0
    }
}

struct PortscanCommand: Command {
    let name = "portscan"; let usage = "portscan host [ports: 22,80,443 | 1-1024]"; let summary = "TCP connect scan"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let host = ctx.args.first else { throw CommandError("usage: \(usage)") }
        var ports: [UInt16] = [21, 22, 23, 25, 53, 80, 110, 143, 443, 445, 587, 993, 995, 1433, 3000, 3306, 3389, 5432, 5900, 6379, 8000, 8080, 8443, 9000, 27017]
        if ctx.args.count > 1 {
            ports = []
            for part in ctx.args[1].split(separator: ",") {
                if let d = part.firstIndex(of: "-"), let a = UInt16(part[..<d]), let b = UInt16(part[part.index(after: d)...]), a <= b { ports += Array(a...b) } else if let p = UInt16(part) { ports.append(p) }
            }
        }
        ctx.print("Scanning \(host) (\(ports.count) ports)...")
        var open: [UInt16] = []
        let batches = stride(from: 0, to: ports.count, by: 64).map { Array(ports[$0..<min($0 + 64, ports.count)]) }
        for batch in batches {
            if Task.isCancelled { return 130 }
            let results = await withTaskGroup(of: (UInt16, Bool).self) { group -> [(UInt16, Bool)] in
                for p in batch {
                    group.addTask {
                        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
                        let ok = (try? await withTimeout(1.5) { try await c.ready() }) ?? false
                        c.cancel(); return (p, ok)
                    }
                }
                var r: [(UInt16, Bool)] = []
                for await x in group { r.append(x) }
                return r
            }
            for (p, ok) in results.sorted(by: { $0.0 < $1.0 }) where ok { open.append(p); ctx.print("\(p)/tcp  \u{1b}[32mopen\u{1b}[0m  \(Ports.name(p))") }
        }
        ctx.print("\(open.count) open port\(open.count == 1 ? "" : "s")")
        return 0
    }
}

enum Ports {
    static func name(_ p: UInt16) -> String {
        [21: "ftp", 22: "ssh", 23: "telnet", 25: "smtp", 53: "dns", 80: "http", 110: "pop3", 143: "imap", 443: "https", 445: "smb", 587: "submission", 993: "imaps", 995: "pop3s", 1433: "mssql", 3000: "dev", 3306: "mysql", 3389: "rdp", 5432: "postgres", 5900: "vnc", 6379: "redis", 8000: "http-alt", 8080: "http-proxy", 8443: "https-alt", 9000: "php-fpm", 27017: "mongodb"][p] ?? ""
    }
}

struct IfconfigCommand: Command {
    let name = "ifconfig"; let usage = "ifconfig"; let summary = "network interfaces and addresses"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { throw CommandError("getifaddrs failed") }
        defer { freeifaddrs(ifaddr) }
        var byName: [String: [String]] = [:]; var order: [String] = []
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr else { continue }
            let name = String(cString: ifa.ifa_name)
            let fam = Int32(sa.pointee.sa_family)
            guard fam == AF_INET || fam == AF_INET6 else { continue }
            let len = fam == AF_INET ? socklen_t(MemoryLayout<sockaddr_in>.size) : socklen_t(MemoryLayout<sockaddr_in6>.size)
            let ip = ICMP.ipString(sa, len)
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append((fam == AF_INET ? "inet " : "inet6 ") + ip + (ifa.ifa_flags & UInt32(IFF_UP) != 0 ? "" : " (down)"))
        }
        for n in order {
            let label = n.hasPrefix("en") ? "wifi/ethernet" : n.hasPrefix("pdp_ip") ? "cellular" : n.hasPrefix("utun") ? "vpn/tunnel" : n == "lo0" ? "loopback" : ""
            ctx.print("\u{1b}[1m\(n)\u{1b}[0m \u{1b}[2m\(label)\u{1b}[0m")
            for a in byName[n] ?? [] { ctx.print("    \(a)") }
        }
        return 0
    }
}

struct WhoisCommand: Command {
    let name = "whois"; let usage = "whois domain|ip"; let summary = "WHOIS lookup (port 43)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let q = ctx.args.first else { throw CommandError("usage: \(usage)") }
        var server = "whois.iana.org"
        if IPv4Address(q) != nil || IPv6Address(q) != nil { server = "whois.arin.net" }
        else if let tld = q.split(separator: ".").last { server = "whois.nic.\(tld)"; if ["com", "net"].contains(tld) { server = "whois.verisign-grs.com" } else if tld == "org" { server = "whois.pir.org" } else if tld == "io" { server = "whois.nic.io" } else if tld == "dev" || tld == "app" { server = "whois.nic.google" } }
        let text = try await Whois.query(server: server, q: q)
        ctx.out.write(text)
        if let refer = text.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("refer:") || $0.lowercased().contains("whois server:") })?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces), refer != server, !refer.isEmpty {
            ctx.print("\n% referred to \(refer)\n")
            ctx.out.write(try await Whois.query(server: refer, q: q))
        }
        return 0
    }
}

enum Whois {
    static func query(server: String, q: String) async throws -> String {
        let conn = NWConnection(host: NWEndpoint.Host(server), port: 43, using: .tcp)
        guard try await withTimeout(8, { try await conn.ready() }) else { conn.cancel(); throw CommandError("\(server): connection timed out") }
        try await conn.sendAsync(Data("\(q)\r\n".utf8))
        var all = Data()
        while let d = try await withTimeoutValue(8, { try await conn.receiveAsync() }) ?? nil { all += d }
        conn.cancel()
        return String(decoding: all, as: UTF8.self)
    }
}

// MARK: - NWConnection async helpers
extension NWConnection {
    func ready() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var done = false
            stateUpdateHandler = { st in
                guard !done else { return }
                switch st {
                case .ready: done = true; c.resume()
                case .failed(let e): done = true; c.resume(throwing: e)
                case .cancelled: done = true; c.resume(throwing: CommandError("cancelled"))
                default: break
                }
            }
            start(queue: .global())
        }
    }
    func sendAsync(_ d: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            send(content: d, completion: .contentProcessed { e in if let e { c.resume(throwing: e) } else { c.resume() } })
        }
    }
    /// Returns nil at end of stream.
    func receiveAsync() async throws -> Data? {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, err in
                if let err { c.resume(throwing: err); return }
                if let data, !data.isEmpty { c.resume(returning: data) } else if complete { c.resume(returning: nil) } else { c.resume(returning: Data()) }
            }
        }
    }
}

/// Runs `op` with a timeout; returns false if it timed out.
func withTimeout(_ seconds: Double, _ op: @escaping () async throws -> Void) async throws -> Bool {
    try await withThrowingTaskGroup(of: Bool.self) { g in
        g.addTask { try await op(); return true }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return false }
        let r = try await g.next() ?? false
        g.cancelAll()
        return r
    }
}
func withTimeoutValue<T>(_ seconds: Double, _ op: @escaping () async throws -> T) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { g in
        g.addTask { try await op() }
        g.addTask { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return nil }
        let r = try await g.next() ?? nil
        g.cancelAll()
        return r
    }
}

/// `telnet`: a TCP terminal with telnet option negotiation (RFC 854): servers asking for options
/// get a polite no except ECHO and SUPPRESS-GO-AHEAD, the window size is announced (NAWS) and the
/// terminal type answered (xterm-256color). Keystrokes go straight through; Ctrl-] disconnects.
/// Echo is local unless the server takes it over. For raw sockets without negotiation, use `nc`.
struct TelnetCommand: Command {
    let name = "telnet"; let usage = "telnet host [port]   (Ctrl-] to disconnect)"
    let summary = "telnet client with option negotiation"
    private enum Cmd: UInt8 { case se = 240, nop = 241, sb = 250, will = 251, wont = 252, doo = 253, dont = 254, iac = 255 }
    private enum Opt: UInt8 { case echo = 1, sga = 3, ttype = 24, naws = 31 }

    func run(_ ctx: CommandContext) async throws -> Int32 {
        let pos = ctx.args.filter { !$0.hasPrefix("-") }
        guard let host = pos.first else { throw CommandError("usage: \(usage)") }
        let port = UInt16(pos.count > 1 ? pos[1] : "23") ?? 23
        guard let input = ctx.acquireRawInput() else { throw CommandError("telnet needs the terminal") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        ctx.print("Trying \(host)...")
        guard try await withTimeout(10, { try await conn.ready() }) else { conn.cancel(); throw CommandError("connect to \(host) port \(port) timed out") }
        ctx.print("Connected to \(host).\nEscape character is '^]'.")
        let (cols, rows) = await ctx.session.size
        var serverEcho = false
        let out = ctx.out
        // Server -> terminal, with the IAC protocol filtered and answered.
        let reader = Task {
            var pending: [UInt8] = []
            while let d = try? await conn.receiveAsync() {
                var plain: [UInt8] = []
                var bytes = pending + [UInt8](d); pending = []
                var i = 0
                while i < bytes.count {
                    let b = bytes[i]
                    guard b == Cmd.iac.rawValue else { plain.append(b); i += 1; continue }
                    guard i + 1 < bytes.count else { pending = [b]; break }
                    let c = bytes[i + 1]
                    switch c {
                    case Cmd.iac.rawValue: plain.append(255); i += 2
                    case Cmd.will.rawValue, Cmd.wont.rawValue, Cmd.doo.rawValue, Cmd.dont.rawValue:
                        guard i + 2 < bytes.count else { pending = Array(bytes[i...]); i = bytes.count; break }
                        let opt = bytes[i + 2]
                        var reply: [UInt8] = []
                        switch (c, opt) {
                        case (Cmd.will.rawValue, Opt.echo.rawValue): serverEcho = true; reply = [255, Cmd.doo.rawValue, opt]
                        case (Cmd.wont.rawValue, Opt.echo.rawValue): serverEcho = false; reply = [255, Cmd.dont.rawValue, opt]
                        case (Cmd.will.rawValue, Opt.sga.rawValue): reply = [255, Cmd.doo.rawValue, opt]
                        case (Cmd.will.rawValue, _): reply = [255, Cmd.dont.rawValue, opt]
                        case (Cmd.doo.rawValue, Opt.sga.rawValue): reply = [255, Cmd.will.rawValue, opt]
                        case (Cmd.doo.rawValue, Opt.ttype.rawValue): reply = [255, Cmd.will.rawValue, opt]
                        case (Cmd.doo.rawValue, Opt.naws.rawValue):
                            reply = [255, Cmd.will.rawValue, opt, 255, Cmd.sb.rawValue, opt, UInt8(cols >> 8), UInt8(cols & 255), UInt8(rows >> 8), UInt8(rows & 255), 255, Cmd.se.rawValue]
                        case (Cmd.doo.rawValue, _): reply = [255, Cmd.wont.rawValue, opt]
                        default: break
                        }
                        if !reply.isEmpty { try? await conn.sendAsync(Data(reply)) }
                        i += 3
                    case Cmd.sb.rawValue:
                        // Subnegotiation up to IAC SE; answer a terminal-type request.
                        guard let end = (i + 2..<max(i + 2, bytes.count - 1)).first(where: { bytes[$0] == 255 && bytes[$0 + 1] == Cmd.se.rawValue }) else { pending = Array(bytes[i...]); i = bytes.count; break }
                        if i + 3 < bytes.count, bytes[i + 2] == Opt.ttype.rawValue, bytes[i + 3] == 1 {
                            try? await conn.sendAsync(Data([255, Cmd.sb.rawValue, Opt.ttype.rawValue, 0] + Array("xterm-256color".utf8) + [255, Cmd.se.rawValue]))
                        }
                        i = end + 2
                    default: i += 2   // NOP, GA, and other two-byte commands
                    }
                }
                if !plain.isEmpty { out.write(String(decoding: plain, as: UTF8.self)) }
            }
            out.write("\nConnection closed by foreign host.\n")
        }
        for await bytes in input {
            if bytes.contains(29) { break }   // Ctrl-]
            var send: [UInt8] = []
            for b in bytes { if b == 255 { send += [255, 255] } else if b == 13 { send += [13, 10] } else { send.append(b) } }
            if !serverEcho { out.write(String(decoding: bytes.map { $0 == 13 ? 10 : $0 }, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")) }
            try? await conn.sendAsync(Data(send))
        }
        reader.cancel(); conn.cancel()
        ctx.print("\nConnection closed.")
        return 0
    }
}
