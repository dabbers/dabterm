import Foundation

/// The on-device workspace. `root` is the app's Documents directory, which is exposed to the
/// Files app ("On My iPhone > dabterm") via UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace.
/// The shell treats it as $HOME.
enum Workspace {
    static let root: URL = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return url.standardizedFileURL
    }()

    static var home: URL { root }
    static var sshDir: URL { root.appendingPathComponent("ssh", isDirectory: true) }
    static var sshConfig: URL { sshDir.appendingPathComponent("config") }
    static var knownHosts: URL { sshDir.appendingPathComponent("known_hosts") }
    static var projectsDir: URL { root.appendingPathComponent("projects", isDirectory: true) }
    static var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }

    /// Create the default folder layout on first launch.
    static func bootstrap() {
        let fm = FileManager.default
        for dir in [sshDir, projectsDir, binDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if !fm.fileExists(atPath: sshConfig.path) {
            let sample = """
            # dabterm SSH config (OpenSSH ssh_config syntax)
            # Keys live next to this file. Generate one with:  ssh-keygen -t ed25519 -f ~/ssh/id_ed25519
            #
            # Host myserver
            #     HostName 192.168.1.10
            #     User root
            #     Port 22
            #     IdentityFile ~/ssh/id_ed25519

            """
            try? sample.write(to: sshConfig, atomically: true, encoding: .utf8)
        }
        if !fm.fileExists(atPath: knownHosts.path) { try? "".write(to: knownHosts, atomically: true, encoding: .utf8) }
        let readme = root.appendingPathComponent("README.txt")
        if !fm.fileExists(atPath: readme.path) {
            let text = """
            This folder is dabterm's home directory (~).
            Anything you put here from the Files app is visible to the shell and the editor.

              ~/projects   clone GitHub repos here (git clone owner/repo)
              ~/ssh        ssh config and keys
              ~/bin        shell scripts (.sh) you can run by name

            Type `help` in the terminal for the list of built-in commands.

            """
            try? text.write(to: readme, atomically: true, encoding: .utf8)
        }
    }

    /// Expand ~ and resolve a path relative to `cwd` into an absolute URL inside or outside the sandbox.
    static func resolve(_ path: String, cwd: URL) -> URL {
        var p = path
        if p == "~" { return home }
        if p.hasPrefix("~/") { p = home.path + p.dropFirst(1) }
        let url = p.hasPrefix("/") ? URL(fileURLWithPath: p) : cwd.appendingPathComponent(p)
        return url.standardizedFileURL
    }

    /// Pretty path: replaces the home prefix with ~.
    static func display(_ url: URL) -> String {
        let p = url.standardizedFileURL.path
        let h = home.path
        if p == h { return "~" }
        if p.hasPrefix(h + "/") { return "~" + p.dropFirst(h.count) }
        return p
    }

    static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }
}
