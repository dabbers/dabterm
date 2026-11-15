import Foundation

/// Parsed OpenSSH `ssh_config`. Supports Host blocks with wildcards, HostName, User, Port,
/// IdentityFile, ProxyJump (first hop only), and `Include` of files next to the config.
struct SSHHostConfig: Identifiable, Hashable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?
    var options: [String: String] = [:]
    var id: String { alias }

    var effectiveHost: String { hostName ?? alias }
    var effectivePort: Int { port ?? 22 }
    var effectiveUser: String { user ?? "root" }
    var isPattern: Bool { alias.contains("*") || alias.contains("?") }
    func resolvedIdentity() -> URL? {
        guard let f = identityFile else { return nil }
        return Workspace.resolve(f.replacingOccurrences(of: "~/.ssh", with: "~/ssh"), cwd: Workspace.home)
    }
}

struct SSHConfig {
    var hosts: [SSHHostConfig] = []
    var defaults = SSHHostConfig(alias: "*")

    static func load(_ url: URL = Workspace.sshConfig) -> SSHConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return SSHConfig() }
        return parse(text, baseDir: url.deletingLastPathComponent())
    }

    static func parse(_ text: String, baseDir: URL) -> SSHConfig {
        var cfg = SSHConfig()
        var current: SSHHostConfig? = nil
        func flush() { if let c = current { if c.alias == "*" { cfg.defaults = c } else { cfg.hosts.append(c) } }; current = nil }
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if let h = line.firstIndex(of: "#") { line = String(line[..<h]).trimmingCharacters(in: .whitespaces) }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" }).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased(), value = parts[1]
            switch key {
            case "host":
                flush()
                // multiple aliases on one Host line become separate entries
                let aliases = value.split(separator: " ").map(String.init)
                for (i, a) in aliases.enumerated() { if i == aliases.count - 1 { current = SSHHostConfig(alias: a) } else { cfg.hosts.append(SSHHostConfig(alias: a)) } }
            case "match": flush(); current = nil
            case "include":
                let inc = Workspace.resolve(value.replacingOccurrences(of: "~/.ssh", with: "~/ssh"), cwd: baseDir)
                if let t = try? String(contentsOf: inc, encoding: .utf8) { let sub = parse(t, baseDir: baseDir); cfg.hosts += sub.hosts }
            case "hostname": current?.hostName = value
            case "user": current?.user = value
            case "port": current?.port = Int(value)
            case "identityfile": current?.identityFile = value
            case "proxyjump": current?.proxyJump = value
            default: current?.options[key] = value
            }
        }
        flush()
        return cfg
    }

    /// Resolve a destination (alias, hostname, or user@host[:port]) into a full config by applying
    /// matching Host blocks (exact first, then patterns) and the `*` defaults.
    func resolve(_ dest: String) -> SSHHostConfig {
        var userOverride: String? = nil, portOverride: Int? = nil
        var target = dest
        if let at = target.lastIndex(of: "@") { userOverride = String(target[..<at]); target = String(target[target.index(after: at)...]) }
        if let colon = target.lastIndex(of: ":"), !target.contains("["), let p = Int(target[target.index(after: colon)...]) { portOverride = p; target = String(target[..<colon]) }
        var result = SSHHostConfig(alias: target)
        var matched = false
        for h in hosts where h.alias == target || (h.isPattern && Glob.match(h.alias, target)) {
            matched = true
            if result.hostName == nil { result.hostName = h.hostName }
            if result.user == nil { result.user = h.user }
            if result.port == nil { result.port = h.port }
            if result.identityFile == nil { result.identityFile = h.identityFile }
            if result.proxyJump == nil { result.proxyJump = h.proxyJump }
            for (k, v) in h.options where result.options[k] == nil { result.options[k] = v }
        }
        _ = matched
        if result.user == nil { result.user = defaults.user }
        if result.port == nil { result.port = defaults.port }
        if result.identityFile == nil { result.identityFile = defaults.identityFile }
        if let u = userOverride { result.user = u }
        if let p = portOverride { result.port = p }
        return result
    }

    /// Appends or replaces a Host block in the config file.
    static func upsert(_ host: SSHHostConfig, in url: URL = Workspace.sshConfig) throws {
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        text = removeBlock(alias: host.alias, from: text)
        var block = "\nHost \(host.alias)\n"
        if let h = host.hostName { block += "    HostName \(h)\n" }
        if let u = host.user { block += "    User \(u)\n" }
        if let p = host.port, p != 22 { block += "    Port \(p)\n" }
        if let i = host.identityFile { block += "    IdentityFile \(i)\n" }
        if let j = host.proxyJump { block += "    ProxyJump \(j)\n" }
        for (k, v) in host.options.sorted(by: { $0.key < $1.key }) { block += "    \(k) \(v)\n" }
        try (text.trimmingCharacters(in: .newlines) + "\n" + block).write(to: url, atomically: true, encoding: .utf8)
    }
    static func remove(alias: String, in url: URL = Workspace.sshConfig) throws {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try removeBlock(alias: alias, from: text).write(to: url, atomically: true, encoding: .utf8)
    }
    private static func removeBlock(alias: String, from text: String) -> String {
        var out: [String] = []; var skipping = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("host ") { skipping = t.dropFirst(5).trimmingCharacters(in: .whitespaces) == alias }
            if !skipping { out.append(line) }
        }
        return out.joined(separator: "\n")
    }
}
