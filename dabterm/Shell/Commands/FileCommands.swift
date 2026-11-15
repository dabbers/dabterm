import Foundation

private let fm = FileManager.default

struct LsCommand: Command {
    let name = "ls"; let usage = "ls [-la] [path...]"; let summary = "list directory contents"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        let long = flags["l"] != nil, all = flags["a"] != nil
        let targets = pos.isEmpty ? ["."] : pos
        var code: Int32 = 0
        for (i, t) in targets.enumerated() {
            let url = ctx.path(t)
            guard fm.fileExists(atPath: url.path) else { ctx.printErr("ls: \(t): No such file or directory"); code = 1; continue }
            var entries: [URL]
            if Workspace.isDirectory(url) {
                entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey], options: all ? [] : [.skipsHiddenFiles])) ?? []
                entries.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                if targets.count > 1 { ctx.print((i > 0 ? "\n" : "") + "\(t):") }
            } else { entries = [url] }
            if long {
                for e in entries { ctx.print(longLine(e)) }
            } else {
                let names = entries.map { e -> String in
                    let n = e.lastPathComponent
                    return Workspace.isDirectory(e) ? "\u{1b}[1;34m\(n)/\u{1b}[0m" : (e.pathExtension == "sh" ? "\u{1b}[32m\(n)\u{1b}[0m" : n)
                }
                let plain = entries.map { $0.lastPathComponent + (Workspace.isDirectory($0) ? "/" : "") }
                let width = await ctx.session.size.cols
                ctx.out.write(colorColumns(names, plain: plain, width: width))
            }
        }
        return code
    }
    private func longLine(_ url: URL) -> String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .contentModificationDateKey])
        let isDir = v?.isDirectory ?? false
        let size = isDir ? "-" : Formatter.bytes(Int64(v?.fileSize ?? 0))
        let df = DateFormatter(); df.dateFormat = "MMM dd HH:mm"
        let date = df.string(from: v?.contentModificationDate ?? Date())
        let n = isDir ? "\u{1b}[1;34m\(url.lastPathComponent)/\u{1b}[0m" : url.lastPathComponent
        return "\(isDir ? "d" : "-")rw-r--r--  \(size.padding(toLength: 7, withPad: " ", startingAt: 0)) \(date)  \(n)"
    }
    private func colorColumns(_ colored: [String], plain: [String], width: Int) -> String {
        guard let maxLen = plain.map(\.count).max(), maxLen > 0 else { return "" }
        let colW = maxLen + 2, cols = max(1, width / colW), rows = (plain.count + cols - 1) / cols
        var out = ""
        for r in 0..<rows {
            var line = ""
            for c in 0..<cols {
                let i = c * rows + r
                if i < plain.count { line += colored[i] + String(repeating: " ", count: colW - plain[i].count) }
            }
            out += line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "\n"
        }
        return out
    }
}

struct CdCommand: Command {
    let name = "cd"; let usage = "cd [dir]"; let summary = "change directory"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let target = ctx.args.first ?? "~"
        let url = target == "-" ? URL(fileURLWithPath: ctx.env["OLDPWD"] ?? Workspace.home.path) : ctx.path(target)
        try await ctx.session.chdir(url)
        return 0
    }
}

struct PwdCommand: Command {
    let name = "pwd"; let usage = "pwd"; let summary = "print working directory"
    func run(_ ctx: CommandContext) async throws -> Int32 { ctx.print(ctx.cwd.path); return 0 }
}

struct CatCommand: Command {
    let name = "cat"; let usage = "cat [-n] [file...]"; let summary = "concatenate and print files"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        var texts: [String] = []
        if pos.isEmpty { texts = [ctx.stdin ?? ""] }
        for p in pos {
            let url = ctx.path(p)
            guard let d = fm.contents(atPath: url.path) else { throw CommandError("\(p): No such file or directory") }
            texts.append(String(decoding: d, as: UTF8.self))
        }
        let joined = texts.joined()
        if flags["n"] != nil {
            for (i, l) in joined.split(separator: "\n", omittingEmptySubsequences: false).enumerated() { ctx.print(String(format: "%6d  ", i + 1) + l) }
        } else { ctx.out.write(joined); if !joined.hasSuffix("\n") && !joined.isEmpty { ctx.out.write("\n") } }
        return 0
    }
}

struct MkdirCommand: Command {
    let name = "mkdir"; let usage = "mkdir [-p] dir..."; let summary = "make directories"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        guard !pos.isEmpty else { throw CommandError("usage: \(usage)") }
        for p in pos { try fm.createDirectory(at: ctx.path(p), withIntermediateDirectories: flags["p"] != nil) }
        return 0
    }
}

struct RmCommand: Command {
    let name = "rm"; let usage = "rm [-rf] path..."; let summary = "remove files or directories"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        guard !pos.isEmpty else { throw CommandError("usage: \(usage)") }
        var code: Int32 = 0
        for p in pos {
            let url = ctx.path(p)
            if url == Workspace.home { throw CommandError("refusing to remove home directory") }
            guard fm.fileExists(atPath: url.path) else { if flags["f"] == nil { ctx.printErr("rm: \(p): No such file or directory"); code = 1 }; continue }
            if Workspace.isDirectory(url) && flags["r"] == nil && flags["R"] == nil { ctx.printErr("rm: \(p): is a directory"); code = 1; continue }
            try fm.removeItem(at: url)
        }
        return code
    }
}

struct MvCommand: Command {
    let name = "mv"; let usage = "mv src... dest"; let summary = "move / rename"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard ctx.args.count >= 2 else { throw CommandError("usage: \(usage)") }
        let dest = ctx.path(ctx.args.last!)
        for s in ctx.args.dropLast() {
            let src = ctx.path(s)
            let target = Workspace.isDirectory(dest) ? dest.appendingPathComponent(src.lastPathComponent) : dest
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: src, to: target)
        }
        return 0
    }
}

struct CpCommand: Command {
    let name = "cp"; let usage = "cp [-r] src... dest"; let summary = "copy files"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse()
        guard pos.count >= 2 else { throw CommandError("usage: \(usage)") }
        let dest = ctx.path(pos.last!)
        for s in pos.dropLast() {
            let src = ctx.path(s)
            if Workspace.isDirectory(src) && flags["r"] == nil && flags["R"] == nil { throw CommandError("\(s) is a directory (use -r)") }
            let target = Workspace.isDirectory(dest) ? dest.appendingPathComponent(src.lastPathComponent) : dest
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: src, to: target)
        }
        return 0
    }
}

struct TouchCommand: Command {
    let name = "touch"; let usage = "touch file..."; let summary = "create empty file or update mtime"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        for p in ctx.args {
            let url = ctx.path(p)
            if fm.fileExists(atPath: url.path) { try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
            else { try Data().write(to: url) }
        }
        return 0
    }
}

struct FindCommand: Command {
    let name = "find"; let usage = "find [path] [-name pattern] [-type f|d]"; let summary = "find files"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var args = ctx.args
        var start = "."
        if let f = args.first, !f.hasPrefix("-") { start = f; args.removeFirst() }
        var pattern: String? = nil, type: String? = nil
        var i = 0
        while i < args.count {
            if args[i] == "-name" || args[i] == "-iname", i + 1 < args.count { pattern = args[i+1]; i += 1 }
            else if args[i] == "-type", i + 1 < args.count { type = args[i+1]; i += 1 }
            i += 1
        }
        let root = ctx.path(start)
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { throw CommandError("\(start): not found") }
        for case let u as URL in en {
            if Task.isCancelled { return 130 }
            let isDir = Workspace.isDirectory(u)
            if type == "f" && isDir { continue }
            if type == "d" && !isDir { continue }
            if let p = pattern, !Glob.match(p.lowercased(), u.lastPathComponent.lowercased()) { continue }
            let rel = u.path.replacingOccurrences(of: root.path, with: start == "." ? "." : start)
            ctx.print(rel)
        }
        return 0
    }
}

struct DuCommand: Command {
    let name = "du"; let usage = "du [-s] [path]"; let summary = "disk usage"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (_, pos) = ctx.parse()
        let root = ctx.path(pos.first ?? ".")
        func size(_ u: URL) -> Int64 {
            if !Workspace.isDirectory(u) { return Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
            return ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).reduce(0) { $0 + size($1) }
        }
        if Workspace.isDirectory(root) {
            for c in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] { ctx.print("\(Formatter.bytes(size(c)).padding(toLength: 8, withPad: " ", startingAt: 0)) \(c.lastPathComponent)") }
        }
        ctx.print("\(Formatter.bytes(size(root)).padding(toLength: 8, withPad: " ", startingAt: 0)) total")
        return 0
    }
}

struct StatCommand: Command {
    let name = "stat"; let usage = "stat file"; let summary = "file status"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let p = ctx.args.first else { throw CommandError("usage: \(usage)") }
        let attrs = try fm.attributesOfItem(atPath: ctx.path(p).path)
        for (k, v) in attrs.sorted(by: { $0.key.rawValue < $1.key.rawValue }) { ctx.print("\(k.rawValue.replacingOccurrences(of: "NSFile", with: "")): \(v)") }
        return 0
    }
}

struct TreeCommand: Command {
    let name = "tree"; let usage = "tree [-a] [-L depth] [path]"; let summary = "directory tree"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let (flags, pos) = ctx.parse(flagsWithValues: ["L"])
        let maxDepth = Int(flags["L"] ?? "") ?? 8
        let root = ctx.path(pos.first ?? ".")
        var dirs = 0, files = 0
        ctx.print(Workspace.display(root))
        func walk(_ u: URL, prefix: String, depth: Int) {
            guard depth < maxDepth, var items = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil, options: flags["a"] == nil ? [.skipsHiddenFiles] : []) else { return }
            items = items.filter { $0.lastPathComponent != "node_modules" && $0.lastPathComponent != ".git" }
            items.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            for (i, item) in items.enumerated() {
                let last = i == items.count - 1
                let isDir = Workspace.isDirectory(item)
                if isDir { dirs += 1 } else { files += 1 }
                ctx.print(prefix + (last ? "└── " : "├── ") + (isDir ? "\u{1b}[1;34m\(item.lastPathComponent)\u{1b}[0m" : item.lastPathComponent))
                if isDir { walk(item, prefix: prefix + (last ? "    " : "│   "), depth: depth + 1) }
            }
        }
        walk(root, prefix: "", depth: 0)
        ctx.print("\n\(dirs) directories, \(files) files")
        return 0
    }
}

struct FileCommand: Command {
    let name = "file"; let usage = "file path..."; let summary = "guess file type"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        for p in ctx.args {
            let url = ctx.path(p)
            if Workspace.isDirectory(url) { ctx.print("\(p): directory"); continue }
            guard let d = fm.contents(atPath: url.path) else { ctx.print("\(p): cannot open"); continue }
            let head = d.prefix(512)
            let kind: String
            if d.isEmpty { kind = "empty" }
            else if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { kind = "PNG image" }
            else if head.starts(with: [0xFF, 0xD8]) { kind = "JPEG image" }
            else if head.starts(with: [0x25, 0x50, 0x44, 0x46]) { kind = "PDF document" }
            else if head.starts(with: [0x50, 0x4B]) { kind = "Zip archive" }
            else if head.starts(with: [0x1F, 0x8B]) { kind = "gzip compressed" }
            else if let s = String(data: head, encoding: .utf8) {
                if s.hasPrefix("#!") { kind = "script text, \(s.split(separator: "\n").first ?? "")" }
                else if s.hasPrefix("-----BEGIN") { kind = "PEM \(s.split(separator: "\n").first?.replacingOccurrences(of: "-", with: "") ?? "")" }
                else if s.hasPrefix("{") || s.hasPrefix("[") { kind = "JSON text" }
                else { kind = "UTF-8 text, \(d.count) bytes" }
            } else { kind = "data, \(d.count) bytes" }
            ctx.print("\(p): \(kind)")
        }
        return 0
    }
}
