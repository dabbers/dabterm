import Foundation
import Citadel
import NIOCore
import NIOSSH
import CryptoKit

/// Shared known_hosts handling: trust-on-first-use, stored in ~/ssh/known_hosts.
final class KnownHostsValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String; let port: Int
    let ask: (String) async -> Bool
    init(host: String, port: Int, ask: @escaping (String) async -> Bool) { self.host = host; self.port = port; self.ask = ask }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        var buf = ByteBuffer(); _ = hostKey.write(to: &buf)
        let blob = Data(buf.readableBytesView)
        let keyLine = blob.base64EncodedString()
        let fp = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let entryHost = port == 22 ? host : "[\(host)]:\(port)"
        let existing = (try? String(contentsOf: Workspace.knownHosts, encoding: .utf8)) ?? ""
        let lines = existing.split(separator: "\n").map(String.init)
        if let known = lines.first(where: { $0.split(separator: " ").first.map { $0.split(separator: ",").contains(Substring(entryHost)) } ?? false }) {
            if known.contains(keyLine) { validationCompletePromise.succeed(()); return }
            validationCompletePromise.fail(CommandError("""
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            The host key for \(entryHost) does not match ~/ssh/known_hosts (\(fp)).
            Remove the old line with:  ssh-keygen -R \(entryHost)
            """))
            return
        }
        Task {
            let ok = await ask("The authenticity of host '\(entryHost)' can't be established.\nKey fingerprint is \(fp).\nAre you sure you want to continue connecting (yes/no)? ")
            if ok {
                let typeName = keyTypeName(blob)
                try? (existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + "\(entryHost) \(typeName) \(keyLine)\n").write(to: Workspace.knownHosts, atomically: true, encoding: .utf8)
                validationCompletePromise.succeed(())
            } else { validationCompletePromise.fail(CommandError("Host key verification failed.")) }
        }
    }
    private func keyTypeName(_ blob: Data) -> String {
        guard blob.count > 4 else { return "unknown" }
        let len = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
        guard blob.count >= 4 + len else { return "unknown" }
        return String(decoding: blob[4..<4+len], as: UTF8.self)
    }
}

/// Interactive line reader on top of the raw terminal input stream (used for prompts like yes/no, passwords).
struct RawLineReader {
    let ctx: CommandContext
    func read(prompt: String, echo: Bool, input: inout AsyncStream<[UInt8]>.Iterator) async -> String? {
        ctx.out.write(prompt)
        var line = ""
        while let bytes = await input.next() {
            for b in bytes {
                switch b {
                case 13, 10: ctx.out.write("\n"); return line
                case 3: ctx.out.write("^C\n"); return nil
                case 127, 8: if !line.isEmpty { line.removeLast(); if echo { ctx.out.write("\u{8} \u{8}") } }
                default: if b >= 32 { line.append(Character(UnicodeScalar(b))); if echo { ctx.out.write(String(UnicodeScalar(b))) } }
                }
            }
        }
        return nil
    }
}

enum SSHConnector {
    /// Connects using config + key discovery + password fallback, with interactive prompts on the terminal.
    static func connect(dest: String, ctx: CommandContext, input: inout AsyncStream<[UInt8]>.Iterator, identity: String? = nil, port portFlag: Int? = nil, user userFlag: String? = nil, verbose: Bool = false) async throws -> (SSHClient, SSHHostConfig) {
        var host = SSHConfig.load().resolve(dest)
        if let p = portFlag { host.port = p }
        if let u = userFlag { host.user = u }
        if let i = identity { host.identityFile = i }
        if verbose { ctx.printErr("debug1: Connecting to \(host.effectiveHost) [\(host.effectiveUser)] port \(host.effectivePort).") }
        let reader = RawLineReader(ctx: ctx)
        // Host key prompt must run on the terminal; the validator asks through this closure.
        let promptBox = PromptBox()
        let validator = KnownHostsValidator(host: host.effectiveHost, port: host.effectivePort) { q in await promptBox.ask(q) }

        var methods: [SSHAuthenticationMethod] = []
        for keyURL in SSHKeys.candidates(for: host) {
            do {
                let k = try SSHKeys.load(keyURL)
                if verbose { ctx.printErr("debug1: Offering public key: \(Workspace.display(keyURL))") }
                switch k {
                case .ed25519(let key): methods.append(.ed25519(username: host.effectiveUser, privateKey: key))
                case .rsa(let key): methods.append(.rsa(username: host.effectiveUser, privateKey: key))
                }
            } catch SSHKeys.KeyError.passphraseRequired {
                let pass = await reader.read(prompt: "Enter passphrase for key '\(Workspace.display(keyURL))': ", echo: false, input: &input) ?? ""
                if let k = try? SSHKeys.load(keyURL, passphrase: pass) {
                    switch k {
                    case .ed25519(let key): methods.append(.ed25519(username: host.effectiveUser, privateKey: key))
                    case .rsa(let key): methods.append(.rsa(username: host.effectiveUser, privateKey: key))
                    }
                } else { ctx.printErr("bad passphrase for \(Workspace.display(keyURL))") }
            } catch { if verbose { ctx.printErr("debug1: skipping \(Workspace.display(keyURL)): \(error)") } }
        }

        // Run the connection concurrently with the prompt pump so host-key questions can be answered.
        let h = host
        func attempt(_ method: SSHAuthenticationMethod) async throws -> SSHClient {
            try await SSHClient.connect(host: h.effectiveHost, port: h.effectivePort, authenticationMethod: method, hostKeyValidator: .custom(validator), reconnect: .never, connectTimeout: .seconds(20))
        }
        var lastError: Error? = nil
        for m in methods {
            let task = Task { try await attempt(m) }
            while !task.isCancelled {
                if let q = await promptBox.pending() {
                    let a = await reader.read(prompt: q, echo: true, input: &input)
                    await promptBox.answer((a ?? "").lowercased().hasPrefix("y"))
                    continue
                }
                if let r = await task.pollResult() {
                    switch r {
                    case .success(let c): return (c, host)
                    case .failure(let e): lastError = e
                        if "\(e)".contains("HOST IDENTIFICATION") || "\(e)".contains("Host key verification") { throw e }
                    }
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        // password fallback
        for _ in 0..<3 {
            guard let pw = await reader.read(prompt: "\(host.effectiveUser)@\(host.effectiveHost)'s password: ", echo: false, input: &input) else { throw CommandError("cancelled") }
            let task = Task { try await attempt(.passwordBased(username: h.effectiveUser, password: pw)) }
            while true {
                if let q = await promptBox.pending() { let a = await reader.read(prompt: q, echo: true, input: &input); await promptBox.answer((a ?? "").lowercased().hasPrefix("y")); continue }
                if let r = await task.pollResult() {
                    switch r { case .success(let c): return (c, host); case .failure(let e): lastError = e; ctx.printErr("Permission denied, please try again.") }
                    break
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw lastError ?? CommandError("connection failed")
    }
}

/// Bridges async host-key questions from the NIO side to the terminal reader.
actor PromptBox {
    private var question: String? = nil
    private var continuation: CheckedContinuation<Bool, Never>? = nil
    func ask(_ q: String) async -> Bool { await withCheckedContinuation { c in question = q; continuation = c } }
    func pending() -> String? { let q = question; question = nil; return q }
    func answer(_ b: Bool) { continuation?.resume(returning: b); continuation = nil }
}

extension Task where Failure == Error {
    /// Non-blocking check for completion.
    func pollResult() async -> Result<Success, Error>? {
        let probe = Task<Result<Success, Error>?, Never> { await self.result }
        let timeout = Task<Result<Success, Error>?, Never> { try? await Task<Never, Never>.sleep(nanoseconds: 10_000_000); return nil }
        let r = await withTaskGroup(of: Result<Success, Error>?.self) { g -> Result<Success, Error>? in
            g.addTask { await probe.value }
            g.addTask { await timeout.value }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        probe.cancel(); timeout.cancel()
        return r
    }
}

struct SSHCommand: Command {
    let name = "ssh"; let usage = "ssh [-p port] [-i key] [-l user] [-v] [user@]host [command]"; let summary = "OpenSSH-compatible client (pubkey, password, ssh/config)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var args = ctx.args
        var port: Int? = nil, identity: String? = nil, user: String? = nil, verbose = false
        var dest: String? = nil, remoteCmd: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if dest == nil {
                switch a {
                case "-p": i += 1; port = Int(args[i])
                case "-i": i += 1; identity = args[i]
                case "-l": i += 1; user = args[i]
                case "-v", "-vv", "-vvv": verbose = true
                case "-o", "-F", "-J", "-L", "-R", "-D": i += 1 // accepted, ignored
                case "-N", "-T", "-t", "-A", "-q", "-C", "-4", "-6": break
                default: if a.hasPrefix("-") { throw CommandError("unknown option \(a)") } else { dest = a }
                }
            } else { remoteCmd.append(a) }
            i += 1
        }
        guard let dest else { throw CommandError("usage: \(usage)") }
        guard let input = ctx.acquireRawInput() else { throw CommandError("ssh needs an interactive terminal") }
        var iter = input.makeAsyncIterator()
        let (client, host) = try await SSHConnector.connect(dest: dest, ctx: ctx, input: &iter, identity: identity, port: port, user: user, verbose: verbose)
        defer { Task { try? await client.close() } }
        if !remoteCmd.isEmpty {
            let out = try await client.executeCommand(remoteCmd.joined(separator: " "), maxResponseSize: 50 * 1024 * 1024)
            ctx.out.write(String(buffer: out))
            return 0
        }
        let (cols, rows) = await ctx.session.size
        await MainActor.run { ctx.session.title = "\(host.effectiveUser)@\(host.alias)" }
        var modes = SSHTerminalModes([:])
        modes = SSHTerminalModes([.ECHO: 1, .ICANON: 1, .ISIG: 1, .ICRNL: 1, .OPOST: 1, .ONLCR: 1, .TTY_OP_ISPEED: 38400, .TTY_OP_OSPEED: 38400])
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(wantReply: true, term: "xterm-256color", terminalCharacterWidth: cols, terminalRowHeight: rows, terminalPixelWidth: 0, terminalPixelHeight: 0, terminalModes: modes)
        do {
            try await client.withPTY(request) { inbound, outbound in
                let writer = outbound
                let resizeHandler: (Int, Int) -> Void = { c, r in Task { try? await writer.changeSize(cols: c, rows: r, pixelWidth: 0, pixelHeight: 0) } }
                await MainActor.run { ctx.session.onResize = resizeHandler }
                let pump = Task {
                    while let bytes = await iter.next() { try await writer.write(ByteBuffer(bytes: bytes)) }
                }
                defer { pump.cancel() }
                for try await chunk in inbound {
                    switch chunk {
                    case .stdout(let b), .stderr(let b): ctx.out.write(String(decoding: b.readableBytesView, as: UTF8.self))
                    }
                }
            }
        } catch {
            if !"\(error)".contains("closed") { ctx.printErr("\(error)") }
        }
        await MainActor.run { ctx.session.onResize = nil; ctx.session.title = Workspace.display(ctx.session.cwd) }
        ctx.print("Connection to \(host.effectiveHost) closed.")
        return 0
    }
}

struct SSHKeygenCommand: Command {
    let name = "ssh-keygen"; let usage = "ssh-keygen [-t ed25519] [-f ~/ssh/id_ed25519] [-C comment] | -l -f key | -y -f key | -R host"; let summary = "generate / inspect SSH keys"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, _) = ctx.parse(flagsWithValues: ["t", "f", "C", "R", "b", "N"])
        if let h = flags["R"] {
            let text = (try? String(contentsOf: Workspace.knownHosts, encoding: .utf8)) ?? ""
            let kept = text.split(separator: "\n").filter { !($0.split(separator: " ").first?.split(separator: ",").contains(Substring(h)) ?? false) }
            try (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: Workspace.knownHosts, atomically: true, encoding: .utf8)
            ctx.print("Host \(h) removed from ~/ssh/known_hosts"); return 0
        }
        let file = ctx.path((flags["f"] ?? "~/ssh/id_ed25519").replacingOccurrences(of: "~/.ssh", with: "~/ssh"))
        if flags["l"] != nil {
            let pubURL = file.pathExtension == "pub" ? file : URL(fileURLWithPath: file.path + ".pub")
            guard let line = try? String(contentsOf: pubURL, encoding: .utf8) else { throw CommandError("\(Workspace.display(pubURL)) not found") }
            ctx.print("256 \(SSHKeys.fingerprint(publicLine: line)) \(line.split(separator: " ").dropFirst(2).joined(separator: " ")) (\(line.split(separator: " ").first.map { $0.replacingOccurrences(of: "ssh-", with: "").uppercased() } ?? ""))")
            return 0
        }
        if flags["y"] != nil {
            let k = try SSHKeys.load(file, passphrase: flags["P"])
            ctx.print(SSHKeys.publicLine(for: k, comment: "")); return 0
        }
        let type = flags["t"] ?? "ed25519"
        guard type == "ed25519" else { throw CommandError("only ed25519 generation is supported on-device (use -t ed25519)") }
        if let n = flags["N"], !n.isEmpty { throw CommandError("passphrase-protected key generation is not supported yet; generate without -N") }
        let keyName = file.lastPathComponent
        if SSHKeyStore.has(keyName) || FileManager.default.fileExists(atPath: file.path) { throw CommandError("a key named \(keyName) already exists") }
        let deviceName = await MainActor.run { UIDeviceName.current }
        let comment = flags["C"] ?? "dabterm@\(deviceName)"
        let (priv, pub) = SSHKeys.generateEd25519(comment: comment)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        // The private key goes to the Keychain (this device only); only the public half is a file.
        SSHKeyStore.store(name: keyName, pem: priv)
        try (pub + "\n").write(to: URL(fileURLWithPath: file.path + ".pub"), atomically: true, encoding: .utf8)
        ctx.print("Your identification has been saved in the Keychain as \(keyName)\nYour public key has been saved in \(Workspace.display(file)).pub\nThe key fingerprint is:\n\(SSHKeys.fingerprint(publicLine: pub)) \(comment)\n\n\(pub)")
        return 0
    }
}

enum UIDeviceName {
    @MainActor static var current: String { UIKit.UIDevice.current.name.replacingOccurrences(of: " ", with: "-") }
}
import UIKit

struct SSHCopyIdCommand: Command {
    let name = "ssh-copy-id"; let usage = "ssh-copy-id [-i key.pub] [user@]host"; let summary = "install your public key on a server"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["i", "p"])
        guard let dest = pos.first else { throw CommandError("usage: \(usage)") }
        var pubURL = ctx.path((flags["i"] ?? "~/ssh/id_ed25519.pub").replacingOccurrences(of: "~/.ssh", with: "~/ssh"))
        if pubURL.pathExtension != "pub" { pubURL = URL(fileURLWithPath: pubURL.path + ".pub") }
        guard let pub = try? String(contentsOf: pubURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else { throw CommandError("no public key at \(Workspace.display(pubURL)); run ssh-keygen first") }
        guard let input = ctx.acquireRawInput() else { throw CommandError("needs a terminal") }
        var iter = input.makeAsyncIterator()
        let (client, _) = try await SSHConnector.connect(dest: dest, ctx: ctx, input: &iter, port: flags["p"].flatMap(Int.init))
        defer { Task { try? await client.close() } }
        let script = "umask 077; mkdir -p ~/.ssh; grep -qF '\(pub)' ~/.ssh/authorized_keys 2>/dev/null || echo '\(pub)' >> ~/.ssh/authorized_keys; echo installed"
        let out = try await client.executeCommand(script)
        ctx.print(String(buffer: out).trimmingCharacters(in: .whitespacesAndNewlines) == "installed" ? "Number of key(s) added: 1\nNow try logging into the machine with: ssh \(dest)" : String(buffer: out))
        return 0
    }
}

struct ScpCommand: Command {
    let name = "scp"; let usage = "scp [-r] [-P port] src dest   (remote side: [user@]host:path)"; let summary = "copy files over SFTP"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["P", "i"])
        guard pos.count == 2 else { throw CommandError("usage: \(usage)") }
        let recursive = flags["r"] != nil
        func split(_ s: String) -> (host: String, path: String)? {
            guard let c = s.firstIndex(of: ":"), !s.hasPrefix("/"), !s.hasPrefix("."), !s.hasPrefix("~") else { return nil }
            return (String(s[..<c]), String(s[s.index(after: c)...]))
        }
        let src = split(pos[0]), dst = split(pos[1])
        guard (src == nil) != (dst == nil) else { throw CommandError("exactly one side must be remote") }
        guard let input = ctx.acquireRawInput() else { throw CommandError("needs a terminal") }
        var iter = input.makeAsyncIterator()
        let (client, _) = try await SSHConnector.connect(dest: (src ?? dst)!.host, ctx: ctx, input: &iter, identity: flags["i"], port: flags["P"].flatMap(Int.init))
        defer { Task { try? await client.close() } }
        let sftp = try await client.openSFTP()
        defer { Task { try? await sftp.close() } }
        var copied = 0
        func upload(_ local: URL, to remotePath: String) async throws {
            if Workspace.isDirectory(local) {
                guard recursive else { throw CommandError("\(local.lastPathComponent) is a directory (use -r)") }
                try? await sftp.createDirectory(atPath: remotePath)
                for item in try FileManager.default.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) { try await upload(item, to: remotePath + "/" + item.lastPathComponent) }
                return
            }
            let data = try Data(contentsOf: local)
            let f = try await sftp.openFile(filePath: remotePath, flags: [.write, .create, .truncate])
            try await f.write(ByteBuffer(bytes: data))
            try await f.close()
            copied += 1
            ctx.print("\(local.lastPathComponent)  \(Formatter.bytes(Int64(data.count)))")
        }
        func download(_ remotePath: String, to local: URL) async throws {
            let attrs = try await sftp.getAttributes(at: remotePath)
            if attrs.permissions.map({ ($0 & 0o40000) != 0 }) ?? false {
                guard recursive else { throw CommandError("\(remotePath) is a directory (use -r)") }
                try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                for entry in try await sftp.listDirectory(atPath: remotePath).flatMap({ $0.components }) where entry.filename != "." && entry.filename != ".." {
                    try await download(remotePath + "/" + entry.filename, to: local.appendingPathComponent(entry.filename))
                }
                return
            }
            let f = try await sftp.openFile(filePath: remotePath, flags: .read)
            let buf = try await f.readAll()
            try await f.close()
            var target = local
            if Workspace.isDirectory(target) { target = target.appendingPathComponent((remotePath as NSString).lastPathComponent) }
            try Data(buf.readableBytesView).write(to: target)
            copied += 1
            ctx.print("\(target.lastPathComponent)  \(Formatter.bytes(Int64(buf.readableBytes)))")
        }
        if let s = src { try await download(s.path.isEmpty ? "." : s.path, to: ctx.path(pos[1])) }
        else if let d = dst {
            let local = ctx.path(pos[0])
            var remote = d.path.isEmpty ? local.lastPathComponent : d.path
            if remote.hasSuffix("/") { remote += local.lastPathComponent }
            try await upload(local, to: remote)
        }
        ctx.print("\(copied) file\(copied == 1 ? "" : "s") copied")
        return 0
    }
}
