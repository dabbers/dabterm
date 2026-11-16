import Foundation
#if canImport(Yaegi)
import Yaegi

/// `git` on go-git (in the Go framework): real repositories with history in `.git`, local
/// commits, branches, diffs, fetch/pull/push over HTTPS (GitHub token) or SSH (keys in ~/ssh).
/// Folders cloned by the older GitHub-API git (a `.dabgit` folder, no `.git`) still go to that
/// implementation, so existing clones keep working until they are re-cloned.
struct GoGitCommand: Command {
    let name = "git"
    let usage = "git <clone|init|status|add|rm|commit|log|diff|show|branch|checkout|switch|merge|pull|fetch|push|remote|tag|reset|config|rev-parse> ..."
    let summary = "git (go-git): clone, commit, branch, diff, push, pull"

    func run(_ ctx: CommandContext) async throws -> Int32 {
        let sub = ctx.args.first ?? ""
        if !["clone", "init", "version", "--version"].contains(sub), Self.usesLegacyState(ctx.cwd) {
            return try await GitCommand().run(ctx)
        }
        let cfg = YaegiNewGitConfig()!
        cfg.cwd = ctx.cwd.path
        cfg.token = Keychain.get(Keychain.githubTokenKey) ?? ""
        cfg.sshDir = Workspace.sshDir.path
        cfg.userName = UserDefaults.standard.string(forKey: "git.user.name") ?? ""
        cfg.userEmail = UserDefaults.standard.string(forKey: "git.user.email") ?? ""
        let out = GoOutput(ctx.out), err = GoOutput(ctx.err)
        let argv = ctx.args.joined(separator: "\u{0}")
        let code: Int = await withCheckedContinuation { cont in
            Thread.detachNewThread { cont.resume(returning: YaegiGit(argv, cfg, out, err)) }
        }
        return Int32(code)
    }

    /// True when the nearest repository marker above cwd is the old `.dabgit` state, not `.git`.
    static func usesLegacyState(_ start: URL) -> Bool {
        var dir = start.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".git").path) { return false }
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(".dabgit").path) { return true }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || !dir.path.hasPrefix(Workspace.root.path) { return false }
            dir = parent
        }
    }
}
#endif
