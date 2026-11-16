import Foundation
import UIKit

/// `git` with GitHub as the object store. Subcommands: clone, status, add, commit, push, pull,
/// log, branch, checkout, remote, diff, show, rm, init (link existing folder to a repo).
struct GitCommand: Command {
    let name = "git"
    let usage = "git <clone|status|add|commit|push|pull|log|branch|checkout|remote|show|diff|init> ..."
    let summary = "GitHub-backed git: clone, commit, push, pull"

    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let sub = ctx.args.first else { throw CommandError("usage: \(usage)") }
        let rest = Array(ctx.args.dropFirst())
        let client = GitHubClient(token: Keychain.get(Keychain.githubTokenKey))
        func repo() throws -> GitRepo {
            guard let r = GitRepo.open(at: ctx.cwd) else { throw CommandError("not a git repository (clone one with `git clone owner/repo` or link with `git init owner/repo`)") }
            return r
        }
        func progress(_ s: String) { ctx.printErr(s) }
        switch sub {
        case "clone":
            guard let spec = rest.first(where: { !$0.hasPrefix("-") }) else { throw CommandError("usage: git clone <owner/repo | https://github.com/owner/repo> [dir] [-b branch]") }
            let (owner, nm) = try parseRepo(spec)
            var branch: String? = nil
            if let i = rest.firstIndex(of: "-b"), i + 1 < rest.count { branch = rest[i+1] }
            let dirArg = rest.filter { !$0.hasPrefix("-") }.dropFirst().first { $0 != branch }
            let dest = ctx.path(dirArg ?? nm)
            if FileManager.default.fileExists(atPath: dest.path), !((try? FileManager.default.contentsOfDirectory(atPath: dest.path))?.isEmpty ?? true) { throw CommandError("destination path '\(dest.lastPathComponent)' already exists and is not empty") }
            ctx.print("Cloning into '\(Workspace.display(dest))'...")
            let r = try await GitRepo.clone(owner: owner, name: nm, branch: branch, into: dest, client: client, progress: progress)
            ctx.print("done. \(r.state.index.count) files on branch \(r.state.branch)")
        case "init":
            guard let spec = rest.first else { throw CommandError("usage: git init owner/repo [-b branch]  (links this folder to an existing GitHub repo; local files win)") }
            let (owner, nm) = try parseRepo(spec)
            let meta = try await client.repo(owner, nm)
            var branch = meta.defaultBranch
            if let i = rest.firstIndex(of: "-b"), i + 1 < rest.count { branch = rest[i+1] }
            let head = try await client.refSHA(owner, nm, branch: branch)
            let commit = try await client.commit(owner, nm, sha: head)
            let entries = try await client.tree(owner, nm, sha: commit.treeSHA)
            var index: [String: String] = [:], modes: [String: String] = [:]
            for e in entries where e.type == "blob" { index[e.path] = e.sha; modes[e.path] = e.mode }
            let r = GitRepo(root: ctx.cwd, state: .init(owner: owner, name: nm, branch: branch, head: head, headTree: commit.treeSHA, index: index, modes: modes))
            try r.save()
            let s = r.status()
            ctx.print("Linked \(Workspace.display(ctx.cwd)) to \(owner)/\(nm) (\(branch)). \(s.modified.count) modified, \(s.added.count) new, \(s.deleted.count) missing locally — run `git pull --force` to take the remote or `git commit -am` to push local.")
        case "status":
            let r = try repo()
            let s = r.status()
            ctx.print("On branch \(r.state.branch)  (\(r.state.owner)/\(r.state.name) @ \(r.state.head.prefix(7)))")
            if s.isClean { ctx.print("nothing to commit, working tree clean"); return 0 }
            if !r.state.staged.isEmpty { ctx.print("\nChanges to be committed:"); for p in r.state.staged.sorted() { ctx.print("\t\u{1b}[32m\(s.added.contains(p) ? "new file" : s.deleted.contains(p) ? "deleted" : "modified"):   \(p)\u{1b}[0m") } }
            let unstaged = (s.modified + s.deleted).filter { !r.state.staged.contains($0) }
            if !unstaged.isEmpty { ctx.print("\nChanges not staged for commit:"); for p in unstaged.sorted() { ctx.print("\t\u{1b}[31m\(s.deleted.contains(p) ? "deleted" : "modified"):   \(p)\u{1b}[0m") } }
            let untracked = s.added.filter { !r.state.staged.contains($0) }
            if !untracked.isEmpty { ctx.print("\nUntracked files:"); for p in untracked { ctx.print("\t\u{1b}[31m\(p)\u{1b}[0m") } }
            ctx.print("\nuse `git add <file>` then `git commit -m` (pushes to GitHub), or `git commit -am \"msg\"` for everything")
        case "add":
            let r = try repo()
            let s = r.status()
            let all = s.modified + s.added + s.deleted
            if rest.contains("-A") || rest.contains(".") || rest.contains("--all") { r.state.staged = Set(all) }
            else {
                for p in rest where !p.hasPrefix("-") {
                    let rel = relPath(ctx.path(p), root: r.root)
                    let matches = all.filter { $0 == rel || $0.hasPrefix(rel + "/") }
                    if matches.isEmpty { ctx.printErr("fatal: pathspec '\(p)' did not match any changed files") } else { r.state.staged.formUnion(matches) }
                }
            }
            try r.save()
        case "rm":
            let r = try repo()
            for p in rest where !p.hasPrefix("-") { try? FileManager.default.removeItem(at: ctx.path(p)); r.state.staged.insert(relPath(ctx.path(p), root: r.root)) }
            try r.save()
        case "commit":
            let r = try repo()
            var message: String? = nil; var all = false
            var i = 0
            while i < rest.count {
                if rest[i] == "-m", i + 1 < rest.count { message = rest[i+1]; i += 1 }
                else if rest[i] == "-am" || rest[i] == "-a" { all = true; if rest[i] == "-am", i + 1 < rest.count { message = rest[i+1]; i += 1 } }
                i += 1
            }
            guard let msg = message, !msg.isEmpty else { throw CommandError("a commit message is required: git commit -m \"message\"") }
            let paths: [String]? = all || r.state.staged.isEmpty ? nil : Array(r.state.staged)
            if paths == nil && !all && r.status().isClean == false && r.state.staged.isEmpty { ctx.printErr("(no files staged; committing all changes — use `git add` to pick files)") }
            let author = authorIdentity()
            let sha = try await r.commitAndPush(message: msg, paths: paths, author: author, client: client, progress: progress)
            ctx.print("[\(r.state.branch) \(sha.prefix(7))] \(msg.split(separator: "\n").first ?? "")\npushed to \(r.state.owner)/\(r.state.name)")
        case "push":
            let r = try repo()
            if r.status().isClean { ctx.print("Everything up-to-date (commits push immediately in dabterm)") } else { ctx.print("You have uncommitted changes. `git commit -am \"msg\"` commits and pushes in one step.") }
        case "pull", "fetch":
            let r = try repo()
            let (n, head) = try await r.pull(client: client, force: rest.contains("--force") || rest.contains("-f"), progress: progress)
            ctx.print(n == 0 ? "Already up to date." : "Updated \(n) file\(n == 1 ? "" : "s") → \(head.prefix(7))")
        case "log":
            let r = try repo()
            let n = Int(rest.first(where: { $0.hasPrefix("-") && Int($0.dropFirst()) != nil })?.dropFirst() ?? "") ?? Int(rest.first(where: { $0.hasPrefix("-n") }).flatMap { _ in rest.last } ?? "") ?? 15
            let oneline = rest.contains("--oneline")
            for c in try await client.log(r.state.owner, r.state.name, sha: r.state.head, count: n) {
                if oneline { ctx.print("\u{1b}[33m\(c.sha.prefix(7))\u{1b}[0m \(c.message.split(separator: "\n").first ?? "")") }
                else { ctx.print("\u{1b}[33mcommit \(c.sha)\u{1b}[0m\nAuthor: \(c.author)\nDate:   \(c.date)\n\n    \(c.message.replacingOccurrences(of: "\n", with: "\n    "))\n") }
            }
        case "branch":
            let r = try repo()
            if rest.contains("-a") || rest.contains("-r") || rest.isEmpty {
                for b in try await client.branches(r.state.owner, r.state.name) { ctx.print((b.name == r.state.branch ? "* \u{1b}[32m" : "  ") + b.name + "\u{1b}[0m") }
            } else if let nm = rest.first(where: { !$0.hasPrefix("-") }) {
                try await client.createRef(r.state.owner, r.state.name, branch: nm, sha: r.state.head); ctx.print("created branch \(nm) at \(r.state.head.prefix(7))")
            }
        case "checkout", "switch":
            let r = try repo()
            let create = rest.contains("-b") || rest.contains("-c")
            guard let nm = rest.last, !nm.hasPrefix("-") else { throw CommandError("usage: git checkout [-b] branch") }
            var isBranch = false
            if rest.first != "--", rest.count == 1, !create, FileManager.default.fileExists(atPath: ctx.path(nm).path) {
                isBranch = ((try? await client.branches(r.state.owner, r.state.name)) ?? []).contains { $0.name == nm }
            }
            if rest.first == "--" || (rest.count == 1 && !create && FileManager.default.fileExists(atPath: ctx.path(nm).path) && !isBranch) {
                // restore a file from HEAD
                let rel = relPath(ctx.path(nm), root: r.root)
                guard let sha = r.state.index[rel] else { throw CommandError("\(nm) is not tracked") }
                try await client.blob(r.state.owner, r.state.name, sha: sha).write(to: r.root.appendingPathComponent(rel))
                ctx.print("Restored \(rel)"); return 0
            }
            try await r.checkout(branch: nm, create: create, client: client, progress: progress)
            ctx.print("Switched to \(create ? "a new " : "")branch '\(nm)'")
        case "remote":
            let r = try repo()
            ctx.print(rest.contains("-v") ? "origin\t\(r.state.remoteURL) (fetch)\norigin\t\(r.state.remoteURL) (push)" : "origin")
        case "show":
            let r = try repo()
            guard let spec = rest.first else {
                let c = try await client.commit(r.state.owner, r.state.name, sha: r.state.head)
                ctx.print("commit \(c.sha)\nAuthor: \(c.author)\nDate:   \(c.date)\n\n    \(c.message)"); return 0
            }
            let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
            let path = parts.count == 2 ? parts[1] : parts[0]
            guard let sha = r.state.index[path] else { throw CommandError("path '\(path)' does not exist at HEAD") }
            ctx.out.write(String(decoding: try await client.blob(r.state.owner, r.state.name, sha: sha), as: UTF8.self))
        case "diff":
            let r = try repo()
            let s = r.status()
            let targets = rest.filter { !$0.hasPrefix("-") }.map { relPath(ctx.path($0), root: r.root) }
            for p in (s.modified + s.added).sorted() where targets.isEmpty || targets.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
                let newText = (try? String(contentsOf: r.root.appendingPathComponent(p), encoding: .utf8)) ?? ""
                var oldText = ""
                if let sha = r.state.index[p] { oldText = String(decoding: try await client.blob(r.state.owner, r.state.name, sha: sha), as: UTF8.self) }
                ctx.print("\u{1b}[1mdiff --git a/\(p) b/\(p)\u{1b}[0m")
                ctx.out.write(UnifiedDiff.make(oldText, newText, name: p))
            }
            for p in s.deleted { ctx.print("\u{1b}[1mdiff --git a/\(p) b/\(p)\u{1b}[0m\n\u{1b}[31mdeleted file\u{1b}[0m") }
        case "config":
            if rest.count >= 2 { UserDefaults.standard.set(rest[1], forKey: "git." + rest[0]); return 0 }
            if let k = rest.first { ctx.print(UserDefaults.standard.string(forKey: "git." + k) ?? ""); return 0 }
            ctx.print("user.name=\(UserDefaults.standard.string(forKey: "git.user.name") ?? "")\nuser.email=\(UserDefaults.standard.string(forKey: "git.user.email") ?? "")")
        case "--version", "version": ctx.print("git version 0.1-dabterm (GitHub API backend)")
        default: throw CommandError("'\(sub)' is not a supported git command\n\(usage)")
        }
        return 0
    }

    func authorIdentity() -> (String, String)? {
        let n = UserDefaults.standard.string(forKey: "git.user.name"), e = UserDefaults.standard.string(forKey: "git.user.email")
        if let n, let e, !n.isEmpty, !e.isEmpty { return (n, e) }
        return nil
    }
    func relPath(_ url: URL, root: URL) -> String { String(url.standardizedFileURL.path.dropFirst(root.path.count + 1)) }
    func parseRepo(_ spec: String) throws -> (String, String) {
        var s = spec
        for p in ["https://github.com/", "http://github.com/", "git@github.com:", "github.com/"] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        if s.hasSuffix("/") { s.removeLast() }
        let parts = s.split(separator: "/")
        guard parts.count == 2 else { throw CommandError("expected owner/repo, got '\(spec)'") }
        return (String(parts[0]), String(parts[1]))
    }
}

enum UnifiedDiff {
    static func make(_ old: String, _ new: String, name: String, context: Int = 3) -> String {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let diff = b.difference(from: a)
        if diff.isEmpty { return "" }
        var marks = [Character](repeating: " ", count: a.count)  // ' ' keep, '-' removed
        var inserts: [Int: [String]] = [:]  // after original index
        for c in diff { if case .remove(let o, _, _) = c { marks[o] = "-" } }
        var ai = 0
        var out: [String] = []
        // Rebuild merged sequence via walking both with the diff applied
        var bIdx = 0
        var merged: [(Character, String)] = []
        var removedSet = Set<Int>(), insertedSet = Set<Int>()
        for c in diff { switch c { case .remove(let o, _, _): removedSet.insert(o); case .insert(let o, _, _): insertedSet.insert(o) } }
        while ai < a.count || bIdx < b.count {
            if ai < a.count, removedSet.contains(ai) { merged.append(("-", a[ai])); ai += 1; continue }
            if bIdx < b.count, insertedSet.contains(bIdx) { merged.append(("+", b[bIdx])); bIdx += 1; continue }
            if ai < a.count, bIdx < b.count { merged.append((" ", a[ai])); ai += 1; bIdx += 1; continue }
            if ai < a.count { merged.append(("-", a[ai])); ai += 1 } else if bIdx < b.count { merged.append(("+", b[bIdx])); bIdx += 1 }
        }
        _ = marks; _ = inserts
        out.append("--- a/\(name)\n+++ b/\(name)")
        var i = 0
        var oldLine = 1, newLine = 1
        while i < merged.count {
            guard merged[i].0 != " " else { oldLine += 1; newLine += 1; i += 1; continue }
            let start = max(0, i - context)
            var end = i
            var lastChange = i
            while end < merged.count, end - lastChange <= context { if merged[end].0 != " " { lastChange = end }; end += 1 }
            end = min(merged.count, lastChange + context + 1)
            let hunk = merged[start..<end]
            let oldStart = oldLine - (i - start), newStart = newLine - (i - start)
            let oldCount = hunk.filter { $0.0 != "+" }.count, newCount = hunk.filter { $0.0 != "-" }.count
            out.append("\u{1b}[36m@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@\u{1b}[0m")
            for (k, l) in hunk { out.append(k == "+" ? "\u{1b}[32m+\(l)\u{1b}[0m" : k == "-" ? "\u{1b}[31m-\(l)\u{1b}[0m" : " \(l)") }
            for (k, _) in hunk { if k != "+" { oldLine += 1 }; if k != "-" { newLine += 1 } }
            i = end
        }
        return out.joined(separator: "\n") + "\n"
    }
}

/// `gh`: auth login/status/logout, repo list/create/view, pr list/create, issue list.
struct GhCommand: Command {
    let name = "gh"; let usage = "gh auth login|status|logout|token  |  gh repo list|create|view  |  gh pr list|create  |  gh issue list"; let summary = "GitHub CLI subset (device-flow login)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let a = ctx.args
        guard a.count >= 1 else { throw CommandError("usage: \(usage)") }
        let client = GitHubClient(token: Keychain.get(Keychain.githubTokenKey))
        switch (a[0], a.count > 1 ? a[1] : "") {
        case ("auth", "login"):
            if let i = a.firstIndex(of: "--with-token"), i >= 0 {
                let tok = (ctx.stdin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tok.isEmpty else { throw CommandError("pipe the token: echo ghp_xxx | gh auth login --with-token") }
                Keychain.set(tok, for: Keychain.githubTokenKey)
                ctx.print("✓ Logged in as \(try await GitHubClient(token: tok).viewer())"); return 0
            }
            guard GitHubClient.deviceFlowConfigured else {
                throw CommandError("device login is not set up in this build: it needs a GitHub OAuth app client id with Device Flow enabled (GitHubClient.clientID).\nUse a token instead: create a fine-grained token at github.com/settings/tokens and run\n  echo <token> | gh auth login --with-token\nor paste it in Settings → GitHub.")
            }
            ctx.print("Starting GitHub device login...")
            let code: GitHubClient.DeviceCode
            do { code = try await GitHubClient.startDeviceFlow() }
            catch { throw CommandError("device flow failed (\(error)).\nAlternative: create a fine-grained token at github.com/settings/tokens and run\n  echo <token> | gh auth login --with-token\nor paste it in Settings → GitHub.") }
            ctx.print("! First copy your one-time code: \u{1b}[1m\(code.userCode)\u{1b}[0m\nOpen \(code.verificationURL) and enter the code. Opening Safari...")
            await MainActor.run { UIPasteboard.general.string = code.userCode; if let u = URL(string: code.verificationURL) { UIApplication.shared.open(u) } }
            for _ in 0..<60 {
                if Task.isCancelled { return 130 }
                try await Task.sleep(nanoseconds: UInt64(max(5, code.interval)) * 1_000_000_000)
                if let tok = try await GitHubClient.pollDeviceFlow(code) {
                    Keychain.set(tok, for: Keychain.githubTokenKey)
                    ctx.print("✓ Authentication complete. Logged in as \(try await GitHubClient(token: tok).viewer())"); return 0
                }
                ctx.out.write(".")
            }
            throw CommandError("timed out waiting for authorization")
        case ("auth", "status"):
            guard client.token != nil else { ctx.print("You are not logged into GitHub. Run `gh auth login`."); return 1 }
            ctx.print("✓ Logged in to github.com as \(try await client.viewer()) (token in Keychain)")
        case ("auth", "logout"): Keychain.delete(Keychain.githubTokenKey); ctx.print("Logged out")
        case ("auth", "token"): guard let t = client.token else { return 1 }; ctx.print(t)
        case ("repo", "list"): for r in try await client.myRepos() { ctx.print(r) }
        case ("repo", "create"):
            guard let nm = a.dropFirst(2).first(where: { !$0.hasPrefix("-") }) else { throw CommandError("usage: gh repo create name [--private] [--clone]") }
            let r = try await client.createRepo(name: nm, isPrivate: a.contains("--private"), description: nil)
            ctx.print("✓ Created repository \(r.fullName)")
            if a.contains("--clone") { let (o, n) = (r.fullName.split(separator: "/").map(String.init)[0], r.fullName.split(separator: "/").map(String.init)[1]); _ = try await GitRepo.clone(owner: o, name: n, branch: nil, into: ctx.path(n), client: client) { ctx.printErr($0) }; ctx.print("✓ Cloned into \(n)") }
        case ("repo", "view"):
            let r = try GitRepo.open(at: ctx.cwd) ?? { throw CommandError("not in a repo") }()
            let meta = try await client.repo(r.state.owner, r.state.name)
            ctx.print("\(meta.fullName)\(meta.isPrivate ? " (private)" : "")\n\(meta.description ?? "")\nhttps://github.com/\(meta.fullName)")
        case ("repo", "clone"): return try await GitCommand().run(await ctx.derived(name: "git", args: ["clone"] + Array(a.dropFirst(2))))
        case ("pr", "list"):
            let r = try GitRepo.open(at: ctx.cwd) ?? { throw CommandError("not in a repo") }()
            for (n, t, h) in try await client.pulls(r.state.owner, r.state.name) { ctx.print("#\(n)\t\(t)\t\u{1b}[36m\(h)\u{1b}[0m") }
        case ("pr", "create"):
            let r = try GitRepo.open(at: ctx.cwd) ?? { throw CommandError("not in a repo") }()
            var title = "", body = "", base = (try await client.repo(r.state.owner, r.state.name)).defaultBranch
            var i = 2
            while i < a.count { if a[i] == "-t" || a[i] == "--title" { title = a[i+1]; i += 1 } else if a[i] == "-b" || a[i] == "--body" { body = a[i+1]; i += 1 } else if a[i] == "-B" || a[i] == "--base" { base = a[i+1]; i += 1 }; i += 1 }
            guard !title.isEmpty else { throw CommandError("usage: gh pr create -t title [-b body] [-B base]") }
            ctx.print(try await client.createPR(r.state.owner, r.state.name, title: title, head: r.state.branch, base: base, body: body))
        case ("issue", "list"):
            let r = try GitRepo.open(at: ctx.cwd) ?? { throw CommandError("not in a repo") }()
            for (n, t) in try await client.issues(r.state.owner, r.state.name) { ctx.print("#\(n)\t\(t)") }
        default: throw CommandError("unsupported: gh \(a.joined(separator: " "))\n\(usage)")
        }
        return 0
    }
}
