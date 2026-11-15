import Foundation
import UIKit

struct HelpCommand: Command {
    let name = "help"; let usage = "help [command]"; let summary = "list commands or show usage"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        if let c = ctx.args.first {
            guard let cmd = CommandRegistry.shared.command(named: c) else { throw CommandError("no such command: \(c)") }
            ctx.print("\u{1b}[1m\(cmd.name)\u{1b}[0m — \(cmd.summary)\n  usage: \(cmd.usage)")
            return 0
        }
        let groups: [(String, [String])] = [
            ("Files", ["ls", "cd", "pwd", "cat", "mkdir", "rm", "mv", "cp", "touch", "find", "tree", "du", "stat", "file", "edit", "open"]),
            ("Text", ["echo", "grep", "head", "tail", "wc", "sort", "uniq", "cut", "tr", "sed", "diff", "jq", "base64", "xxd", "tee"]),
            ("Network", ["ping", "traceroute", "dig", "host", "curl", "wget", "http", "nc", "portscan", "ifconfig", "whois"]),
            ("Crypto", ["openssl", "shasum", "md5", "uuid", "ssh-keygen"]),
            ("Remote", ["ssh", "scp", "ssh-copy-id", "git", "gh"]),
            ("Shell", ["help", "clear", "history", "env", "export", "unset", "alias", "which", "date", "uname", "sleep", "sh", "exit"]),
        ]
        ctx.print("\u{1b}[1mdabterm built-in commands\u{1b}[0m  (help <cmd> for usage; .sh files in ~/bin run by name)\n")
        for (title, names) in groups {
            ctx.print("\u{1b}[1;36m\(title)\u{1b}[0m")
            for n in names { if let c = CommandRegistry.shared.command(named: n) { ctx.print("  \u{1b}[1m\(n.padding(toLength: 12, withPad: " ", startingAt: 0))\u{1b}[0m \(c.summary)") } }
        }
        ctx.print("\nKeys: Ctrl-C cancel · Ctrl-L clear · Tab complete · ↑/↓ history · Ctrl-A/E line start/end · Ctrl-U/K/W kill")
        return 0
    }
}

struct ClearCommand: Command {
    let name = "clear"; let usage = "clear"; let summary = "clear the screen"
    func run(_ ctx: CommandContext) async throws -> Int32 { await ctx.session.writeRaw("\u{1b}[2J\u{1b}[3J\u{1b}[H"); return 0 }
}

struct HistoryCommand: Command {
    let name = "history"; let usage = "history [-c]"; let summary = "command history"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        if ctx.args.first == "-c" { await MainActor.run { ctx.session.history = [] }; try? FileManager.default.removeItem(at: ShellSession.historyURL); return 0 }
        let h = await ctx.session.history
        for (i, l) in h.enumerated() { ctx.print(String(format: "%5d  %@", i + 1, l)) }
        return 0
    }
}

struct EnvCommand: Command {
    let name = "env"; let usage = "env"; let summary = "print environment"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let env = await ctx.session.env
        for (k, v) in env.sorted(by: { $0.key < $1.key }) where k != "?" && Int(k) == nil { ctx.print("\(k)=\(v)") }
        return 0
    }
}
struct PrintenvCommand: Command {
    let name = "printenv"; let usage = "printenv [VAR]"; let summary = "print an environment variable"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let env = await ctx.session.env
        if let k = ctx.args.first { if let v = env[k] { ctx.print(v); return 0 }; return 1 }
        return try await EnvCommand().run(ctx)
    }
}

struct ExportCommand: Command {
    let name = "export"; let usage = "export NAME=value"; let summary = "set environment variable"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        for a in ctx.args {
            guard let eq = a.firstIndex(of: "=") else { continue }
            let k = String(a[..<eq]), v = String(a[a.index(after: eq)...])
            await MainActor.run { ctx.session.env[k] = v }
        }
        return 0
    }
}
struct UnsetCommand: Command {
    let name = "unset"; let usage = "unset NAME"; let summary = "remove environment variable"
    func run(_ ctx: CommandContext) async throws -> Int32 { for a in ctx.args { await MainActor.run { ctx.session.env[a] = nil } }; return 0 }
}

struct AliasCommand: Command {
    let name = "alias"; let usage = "alias name='command args'"; let summary = "define a command alias (session only)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        if ctx.args.isEmpty {
            for c in CommandRegistry.shared.all.compactMap({ $0 as? AliasedCommand }) { ctx.print("alias \(c.name)='\(c.target) \(c.prefix.joined(separator: " "))'") }
            return 0
        }
        for a in ctx.args {
            guard let eq = a.firstIndex(of: "=") else { throw CommandError("usage: \(usage)") }
            let n = String(a[..<eq])
            let parts = String(a[a.index(after: eq)...]).split(separator: " ").map(String.init)
            guard let target = parts.first else { continue }
            CommandRegistry.shared.register(AliasedCommand(name: n, target: target, prefix: Array(parts.dropFirst())))
        }
        return 0
    }
}

struct WhichCommand: Command {
    let name = "which"; let usage = "which command"; let summary = "locate a command"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var code: Int32 = 0
        for a in ctx.args {
            if CommandRegistry.shared.command(named: a) != nil { ctx.print("\(a): dabterm built-in") }
            else if FileManager.default.fileExists(atPath: Workspace.binDir.appendingPathComponent(a).path) { ctx.print(Workspace.binDir.appendingPathComponent(a).path) }
            else if FileManager.default.fileExists(atPath: Workspace.binDir.appendingPathComponent(a + ".sh").path) { ctx.print(Workspace.binDir.appendingPathComponent(a + ".sh").path) }
            else { ctx.print("\(a) not found"); code = 1 }
        }
        return code
    }
}

struct DateCommand: Command {
    let name = "date"; let usage = "date [-u] [+format]"; let summary = "current date and time"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        let df = DateFormatter()
        if flags["u"] != nil { df.timeZone = TimeZone(identifier: "UTC") }
        if let f = pos.first, f.hasPrefix("+") {
            if f == "+%s" { ctx.print(String(Int(Date().timeIntervalSince1970))); return 0 }
            let map = ["%Y": "yyyy", "%m": "MM", "%d": "dd", "%H": "HH", "%M": "mm", "%S": "ss", "%Z": "zzz", "%a": "EEE", "%b": "MMM", "%F": "yyyy-MM-dd", "%T": "HH:mm:ss"]
            var fmt = String(f.dropFirst())
            for (k, v) in map { fmt = fmt.replacingOccurrences(of: k, with: v) }
            df.dateFormat = fmt
        } else { df.dateFormat = "EEE MMM d HH:mm:ss zzz yyyy" }
        ctx.print(df.string(from: Date()))
        return 0
    }
}

struct UnameCommand: Command {
    let name = "uname"; let usage = "uname [-a]"; let summary = "system information"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let d = await UIDevice.current
        let (model, sys, ver) = await (d.model, d.systemName, d.systemVersion)
        if ctx.args.contains("-a") { ctx.print("dabterm \(model) \(sys) \(ver) arm64") } else { ctx.print(sys) }
        return 0
    }
}

struct SleepCommand: Command {
    let name = "sleep"; let usage = "sleep seconds"; let summary = "pause"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let s = Double(ctx.args.first ?? "1") ?? 1
        try await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
        return 0
    }
}
struct TrueCommand: Command { let name = "true"; let usage = "true"; let summary = "exit 0"; func run(_ ctx: CommandContext) async throws -> Int32 { 0 } }
struct FalseCommand: Command { let name = "false"; let usage = "false"; let summary = "exit 1"; func run(_ ctx: CommandContext) async throws -> Int32 { 1 } }
struct ExitCommand: Command {
    let name = "exit"; let usage = "exit"; let summary = "reset the shell"
    func run(_ ctx: CommandContext) async throws -> Int32 { ctx.print("(dabterm has no parent process; the shell stays open)"); return 0 }
}

struct ShCommand: Command {
    let name = "sh"; let usage = "sh script.sh [args]  |  sh -c 'cmd'"; let summary = "run a shell script"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        if ctx.args.first == "-c", ctx.args.count > 1 { await ctx.session.execute(line: ctx.args[1]); return Int32(await ctx.session.env["?"] ?? "0") ?? 0 }
        guard let s = ctx.args.first else { throw CommandError("usage: \(usage)") }
        return await ctx.session.runScript(ctx.path(s), args: Array(ctx.args.dropFirst()))
    }
}

struct EditCommand: Command {
    let name = "edit"; let usage = "edit file|folder"; let summary = "open in the code editor tab"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let url = ctx.path(ctx.args.first ?? ".")
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
        await MainActor.run { ctx.session.openInEditor?(url) }
        return 0
    }
}

struct OpenCommand: Command {
    let name = "open"; let usage = "open url|file"; let summary = "open a URL in Safari or a file in the editor"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let a = ctx.args.first else { throw CommandError("usage: \(usage)") }
        if let u = URL(string: a), let scheme = u.scheme, ["http", "https"].contains(scheme) {
            await MainActor.run { UIApplication.shared.open(u) }
        } else { return try await EditCommand().run(ctx) }
        return 0
    }
}

struct UUIDCommand: Command {
    let name = "uuid"; let usage = "uuid"; let summary = "generate a UUID"
    func run(_ ctx: CommandContext) async throws -> Int32 { ctx.print(UUID().uuidString.lowercased()); return 0 }
}
