import Foundation

/// Tool packs: directories with a `pack.json` manifest that add commands to the shell without an
/// app update. Commands are JavaScript (run on JavaScriptCore, which the App Store allows to load
/// at runtime) or dsh scripts.
///
/// Locations, later ones win on name conflicts:
///   1. bundled   <app>/packs/<name>/            shipped with the build (updated at release time)
///   2. user      ~/packs/<name>/                installed with `pack install`, or dropped in via Files
///
/// pack.json:
/// {
///   "name": "core-tools", "version": "1.2.0", "description": "...",
///   "source": "dabbers/dabterm-packs/core-tools",        // GitHub owner/repo[/path] or https://.../pack.json
///   "commands": [
///     { "name": "jsonfmt", "kind": "js", "entry": "jsonfmt.js", "summary": "...", "usage": "..." },
///     { "name": "hello",   "kind": "sh", "entry": "hello.sh" }
///   ]
/// }
struct PackManifest: Codable {
    struct Cmd: Codable {
        var name: String
        var kind: String          // "js" | "sh"
        var entry: String
        var summary: String?
        var usage: String?
    }
    var name: String
    var version: String
    var description: String?
    var source: String?
    var minApp: String?
    var commands: [Cmd]
    var files: [String]?          // for manifest-URL installs: files to fetch next to pack.json
}

struct ToolPack: Identifiable {
    let manifest: PackManifest
    let root: URL
    let bundled: Bool
    var id: String { manifest.name }
}

/// A command provided by a pack.
struct PackCommand: Command {
    let pack: ToolPack
    let cmd: PackManifest.Cmd
    var name: String { cmd.name }
    var usage: String { cmd.usage ?? cmd.name }
    var summary: String { (cmd.summary ?? "") + "  \u{1b}[2m[\(pack.manifest.name)]\u{1b}[0m" }
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let entry = pack.root.appendingPathComponent(cmd.entry)
        switch cmd.kind {
        case "js":
            return try await JSCommand().run(await ctx.derived(name: cmd.name, args: [entry.path] + ctx.args))
        case "sh":
            return await ctx.session.runScript(entry, args: ctx.args)
        default:
            throw CommandError("pack \(pack.manifest.name): unsupported command kind '\(cmd.kind)' (js, sh)")
        }
    }
}

@MainActor
final class ToolPackManager {
    static let shared = ToolPackManager()
    private(set) var packs: [String: ToolPack] = [:]
    private(set) var commands: [String: PackCommand] = [:]
    nonisolated static var userDir: URL { Workspace.root.appendingPathComponent("packs", isDirectory: true) }
    static var bundledDir: URL? { Bundle.main.url(forResource: "packs", withExtension: nil) }

    func reload() {
        packs = [:]; commands = [:]
        var roots: [(URL, Bool)] = []
        if let b = Self.bundledDir { roots.append((b, true)) }
        roots.append((Self.userDir, false))
        for (dir, bundled) in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { continue }
            for item in items where Workspace.isDirectory(item) {
                guard let pack = Self.load(item, bundled: bundled) else { continue }
                if let existing = packs[pack.manifest.name], !existing.bundled, bundled { continue }
                packs[pack.manifest.name] = pack
            }
        }
        for pack in packs.values {
            for c in pack.manifest.commands {
                if CommandRegistry.shared.isBuiltin(c.name) { continue }   // built-ins always win
                commands[c.name] = PackCommand(pack: pack, cmd: c)
            }
        }
    }

    static func load(_ dir: URL, bundled: Bool) -> ToolPack? {
        guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent("pack.json").path),
              let m = try? JSONDecoder().decode(PackManifest.self, from: data) else { return nil }
        return ToolPack(manifest: m, root: dir, bundled: bundled)
    }

    // MARK: install / update
    /// `spec` is `owner/repo`, `owner/repo/sub/dir`, `https://github.com/owner/repo[/tree/branch/dir]`,
    /// or an https URL ending in pack.json (files listed in `files` are fetched next to it).
    func install(_ spec: String, progress: @escaping (String) -> Void) async throws -> ToolPack {
        try FileManager.default.createDirectory(at: Self.userDir, withIntermediateDirectories: true)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("pack-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        if spec.hasSuffix("pack.json"), let url = URL(string: spec) {
            progress("Fetching \(spec)")
            let (data, _) = try await URLSession.shared.data(from: url)
            let m = try JSONDecoder().decode(PackManifest.self, from: data)
            try data.write(to: staging.appendingPathComponent("pack.json"))
            let base = url.deletingLastPathComponent()
            let files = Set((m.files ?? []) + m.commands.map(\.entry))
            for f in files {
                progress("Fetching \(f)")
                let (d, resp) = try await URLSession.shared.data(from: base.appendingPathComponent(f))
                guard (resp as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { throw CommandError("\(f): not found at \(base)") }
                let dest = staging.appendingPathComponent(f)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try d.write(to: dest)
            }
        } else {
            let (owner, repo, ref, path) = try Self.parseGitHubSpec(spec)
            let client = GitHubClient(token: Keychain.get(Keychain.githubTokenKey))
            let branch: String
            if let ref { branch = ref } else { branch = try await client.repo(owner, repo).defaultBranch }
            let head = try await client.refSHA(owner, repo, branch: branch)
            let commit = try await client.commit(owner, repo, sha: head)
            let entries = try await client.tree(owner, repo, sha: commit.treeSHA)
            let prefix = path.isEmpty ? "" : path + "/"
            let blobs = entries.filter { $0.type == "blob" && $0.path.hasPrefix(prefix) }
            guard blobs.contains(where: { $0.path == prefix + "pack.json" }) else { throw CommandError("no pack.json at \(owner)/\(repo)/\(path) on \(branch)") }
            progress("Downloading \(blobs.count) files from \(owner)/\(repo)\(path.isEmpty ? "" : "/" + path)@\(branch)")
            for b in blobs {
                let rel = String(b.path.dropFirst(prefix.count))
                if rel.hasPrefix(".") || rel.contains("/.") { continue }
                let data = try await client.blob(owner, repo, sha: b.sha)
                let dest = staging.appendingPathComponent(rel)
                try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: dest)
            }
            // remember where it came from for `pack update`
            if var m = Self.load(staging, bundled: false)?.manifest {
                if m.source == nil { m.source = spec }
                try JSONEncoder().encode(m).write(to: staging.appendingPathComponent("pack.json"))
            }
        }
        guard let pack = Self.load(staging, bundled: false) else { throw CommandError("downloaded pack has an invalid pack.json") }
        for c in pack.manifest.commands where !FileManager.default.fileExists(atPath: staging.appendingPathComponent(c.entry).path) {
            throw CommandError("pack \(pack.manifest.name): entry '\(c.entry)' for command \(c.name) is missing")
        }
        let dest = Self.userDir.appendingPathComponent(pack.manifest.name)
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: staging, to: dest)
        reload()
        return packs[pack.manifest.name]!
    }

    func remove(_ name: String) throws {
        guard let p = packs[name] else { throw CommandError("no pack named \(name)") }
        guard !p.bundled else { throw CommandError("\(name) is bundled with the app; it cannot be removed (user packs override it)") }
        try FileManager.default.removeItem(at: p.root)
        reload()
    }

    static func parseGitHubSpec(_ spec: String) throws -> (owner: String, repo: String, ref: String?, path: String) {
        var s = spec
        var ref: String? = nil
        for p in ["https://github.com/", "http://github.com/", "github.com/"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        var parts = s.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { throw CommandError("expected owner/repo[/path], a GitHub URL, or a pack.json URL") }
        let owner = parts.removeFirst(), repo = parts.removeFirst().replacingOccurrences(of: ".git", with: "")
        if parts.first == "tree", parts.count >= 2 { parts.removeFirst(); ref = parts.removeFirst() }
        if let at = repo.firstIndex(of: "@") { ref = String(repo[repo.index(after: at)...]) }
        return (owner, repo.split(separator: "@").first.map(String.init) ?? repo, ref, parts.joined(separator: "/"))
    }
}

struct PackCLICommand: Command {
    let name = "pack"
    let usage = "pack list | info <name> | install <owner/repo[/dir] | url/pack.json> | update [name] | remove <name> | reload | new <name>"
    let summary = "manage tool packs (add commands without an app update)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let mgr = await ToolPackManager.shared
        let sub = ctx.args.first ?? "list"
        let arg = ctx.args.count > 1 ? ctx.args[1] : nil
        switch sub {
        case "list", "ls":
            let packs = await mgr.packs.values.sorted { $0.manifest.name < $1.manifest.name }
            if packs.isEmpty { ctx.print("no packs installed. Try: pack install dabbers/dabterm/dabterm/Resources/packs/core-tools"); return 0 }
            for p in packs {
                ctx.print("\u{1b}[1m\(p.manifest.name)\u{1b}[0m \(p.manifest.version)  \u{1b}[2m\(p.bundled ? "bundled" : "~/packs")\u{1b}[0m  \(p.manifest.description ?? "")")
                ctx.print("  " + p.manifest.commands.map(\.name).joined(separator: "  "))
            }
            ctx.print("\nPacks are plain folders in Files → dabterm → packs; edit the .js files there and run `pack reload`.")
        case "info":
            guard let n = arg, let p = await mgr.packs[n] else { throw CommandError("usage: pack info <name>") }
            ctx.print("\(p.manifest.name) \(p.manifest.version)\n\(p.manifest.description ?? "")\nlocation: \(Workspace.display(p.root))\nsource: \(p.manifest.source ?? "-")")
            for c in p.manifest.commands { ctx.print("  \(c.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(c.kind)  \(c.entry)  \(c.summary ?? "")") }
        case "install", "add":
            guard let spec = arg else { throw CommandError("usage: pack install <owner/repo[/dir] | https://.../pack.json>") }
            let p = try await mgr.install(spec) { ctx.printErr($0) }
            ctx.print("✓ installed \(p.manifest.name) \(p.manifest.version): \(p.manifest.commands.map(\.name).joined(separator: " "))")
        case "update", "upgrade":
            let installed = await mgr.packs.values.filter { !$0.bundled }.map(\.manifest.name)
            let targets = arg.map { [$0] } ?? installed
            for n in targets {
                guard let p = await mgr.packs[n] else { ctx.printErr("no pack named \(n)"); continue }
                guard let src = p.manifest.source else { ctx.printErr("\(n): no source recorded; reinstall with pack install"); continue }
                let old = p.manifest.version
                let np = try await mgr.install(src) { ctx.printErr($0) }
                ctx.print(np.manifest.version == old ? "\(n) is up to date (\(old))" : "✓ \(n) \(old) → \(np.manifest.version)")
            }
        case "remove", "rm", "uninstall":
            guard let n = arg else { throw CommandError("usage: pack remove <name>") }
            try await mgr.remove(n); ctx.print("removed \(n)")
        case "reload": await mgr.reload(); ctx.print("reloaded \(await mgr.packs.count) packs, \(await mgr.commands.count) commands")
        case "new":
            guard let n = arg else { throw CommandError("usage: pack new <name>") }
            let dir = ToolPackManager.userDir.appendingPathComponent(n)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let manifest = PackManifest(name: n, version: "0.1.0", description: "My tools", source: nil, minApp: nil, commands: [.init(name: "hello-\(n)", kind: "js", entry: "hello.js", summary: "example command", usage: "hello-\(n) [name]")], files: nil)
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(manifest).write(to: dir.appendingPathComponent("pack.json"))
            try "// args after the command name are in process.argv.slice(2); piped input in readStdin()\nconst who = process.argv[2] || 'world';\nconsole.log(`hello, ${who}!`);\n".write(to: dir.appendingPathComponent("hello.js"), atomically: true, encoding: .utf8)
            await mgr.reload()
            ctx.print("created \(Workspace.display(dir)) — try `hello-\(n)`; edit with `edit \(Workspace.display(dir))`")
        default: throw CommandError("usage: \(usage)")
        }
        return 0
    }
}
