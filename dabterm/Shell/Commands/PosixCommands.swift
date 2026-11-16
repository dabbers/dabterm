import Foundation
import SQLite3

// Small POSIX staples the shell lacked: xargs, time, watch, less, patch, and a sqlite3 shell.

private func posixQuote(_ s: String) -> String {
    if s.isEmpty { return "''" }
    if s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:,@+%".contains($0) }) { return s }
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct XargsCommand: Command {
    let name = "xargs"; let usage = "xargs [-n N] [-I {}] [-0] command [args...]"
    let summary = "build command lines from stdin and run them"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var perLine: Int? = nil, placeholder: String? = nil, nul = false
        while let f = a.first, f.hasPrefix("-") {
            a.removeFirst()
            switch f {
            case "-n": guard let n = a.first.flatMap(Int.init) else { throw CommandError("-n needs a number") }; perLine = n; a.removeFirst()
            case "-I": guard !a.isEmpty else { throw CommandError("-I needs a placeholder") }; placeholder = a.removeFirst(); perLine = 1
            case "-0": nul = true
            default: if f.hasPrefix("-n"), let n = Int(f.dropFirst(2)) { perLine = n } else { throw CommandError("unknown option \(f)") }
            }
        }
        if a.isEmpty { a = ["echo"] }
        let input = ctx.stdin ?? ""
        let items: [String] = nul ? input.split(separator: "\u{0}").map(String.init)
                                  : input.split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" }).map(String.init)
        guard !items.isEmpty else { return 0 }
        var status: Int32 = 0
        let groups: [[String]] = perLine.map { n in stride(from: 0, to: items.count, by: n).map { Array(items[$0..<min($0 + n, items.count)]) } } ?? [items]
        for g in groups {
            if ctx.isCancelled { return 130 }
            let line: String
            if let ph = placeholder {
                line = a.map { posixQuote($0.replacingOccurrences(of: ph, with: g.joined(separator: " "))) }.joined(separator: " ")
            } else {
                line = (a.map(posixQuote) + g.map(posixQuote)).joined(separator: " ")
            }
            let code = await ShellRegistry.shared.current.execute(line: line, session: ctx.session)
            if code != 0 { status = 123 }
        }
        return status
    }
}

struct TimeCommand: Command {
    let name = "time"; let usage = "time command [args...]"
    let summary = "time a command"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard !ctx.args.isEmpty else { throw CommandError("usage: \(usage)") }
        let line = ctx.args.map(posixQuote).joined(separator: " ")
        let start = Date()
        let code = await ShellRegistry.shared.current.execute(line: line, session: ctx.session)
        let secs = Date().timeIntervalSince(start)
        ctx.printErr(String(format: "\nreal\t%dm%.3fs", Int(secs) / 60, secs - Double(Int(secs) / 60 * 60)))
        return code
    }
}

struct WatchCommand: Command {
    let name = "watch"; let usage = "watch [-n seconds] command [args...]   (q or Ctrl-C stops)"
    let summary = "run a command repeatedly, showing its output"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var interval = 2.0
        if a.first == "-n", a.count > 1, let n = Double(a[1]) { interval = max(0.1, n); a.removeFirst(2) }
        guard !a.isEmpty else { throw CommandError("usage: \(usage)") }
        let line = a.map(posixQuote).joined(separator: " ")
        // Keys arrive on the raw stream; q ends the loop.
        var stopped = false
        var keys: Task<Void, Never>? = nil
        if let raw = ctx.acquireRawInput() {
            keys = Task { for await b in raw { if b.contains(UInt8(ascii: "q")) || b.contains(3) { stopped = true; break } } }
        }
        defer { keys?.cancel() }
        while !stopped && !ctx.isCancelled {
            let buffer = StringSink()
            _ = await ctx.session.runSimple(name: "sh", args: ["-c", line], stdin: nil, out: buffer, err: buffer)
            let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
            ctx.out.write("\u{1b}[H\u{1b}[2JEvery \(interval)s: \(line)    \(stamp)\n\n" + buffer.buffer)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        ctx.out.write("\n")
        return 0
    }
}

struct LessCommand: Command {
    let name = "less"; let usage = "less [file]   (space/f next page, b back, j/k line, g/G ends, /text search, q quit)"
    let summary = "page through text"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        let text: String
        if let f = ctx.args.first(where: { !$0.hasPrefix("-") }) {
            guard let d = FileManager.default.contents(atPath: ctx.path(f).path) else { throw CommandError("\(f): No such file or directory") }
            text = String(decoding: d, as: UTF8.self)
        } else { text = ctx.stdin ?? "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let (cols, rows) = await ctx.session.size
        let page = max(1, rows - 1)
        guard lines.count > page, let raw = ctx.acquireRawInput() else { ctx.out.write(text); if !text.hasSuffix("\n") { ctx.out.write("\n") }; return 0 }
        var top = 0
        var search = ""
        func draw() {
            var s = "\u{1b}[H\u{1b}[2J"
            for i in top..<min(top + page, lines.count) { s += String(lines[i].prefix(cols)) + "\n" }
            let pct = lines.count > 0 ? Int(Double(min(top + page, lines.count)) / Double(lines.count) * 100) : 100
            s += "\u{1b}[7m lines \(top + 1)-\(min(top + page, lines.count)) of \(lines.count) (\(pct)%) \u{1b}[0m"
            ctx.out.write(s)
        }
        draw()
        var it = raw.makeAsyncIterator()
        var pending = ""
        var searching = false
        loop: while let bytes = await it.next() {
            for b in bytes {
                if searching {
                    switch b {
                    case 13, 10:
                        searching = false
                        if let i = lines.indices.first(where: { $0 > top && lines[$0].contains(search) }) { top = i }
                    case 127, 8: if !search.isEmpty { search.removeLast() }
                    case 27: searching = false
                    default: if b >= 32 { search.append(Character(UnicodeScalar(b))) }
                    }
                    if searching { ctx.out.write("\u{1b}[\(page + 1);1H\u{1b}[2K/\(search)") } else { draw() }
                    continue
                }
                if !pending.isEmpty || b == 27 {
                    pending.append(Character(UnicodeScalar(b)))
                    if pending.count < 3 { continue }
                    switch pending { case "\u{1b}[A": top = max(0, top - 1); case "\u{1b}[B": top = min(max(0, lines.count - page), top + 1); default: break }
                    pending = ""; draw(); continue
                }
                switch b {
                case UInt8(ascii: "q"), 3: break loop
                case UInt8(ascii: " "), UInt8(ascii: "f"): top = min(max(0, lines.count - page), top + page)
                case UInt8(ascii: "b"): top = max(0, top - page)
                case UInt8(ascii: "j"), 13: top = min(max(0, lines.count - page), top + 1)
                case UInt8(ascii: "k"): top = max(0, top - 1)
                case UInt8(ascii: "g"): top = 0
                case UInt8(ascii: "G"): top = max(0, lines.count - page)
                case UInt8(ascii: "/"): searching = true; search = ""; ctx.out.write("\u{1b}[\(page + 1);1H\u{1b}[2K/"); continue
                case UInt8(ascii: "n"): if let i = lines.indices.first(where: { $0 > top && lines[$0].contains(search) }) { top = i }
                default: continue
                }
                draw()
            }
        }
        ctx.out.write("\u{1b}[H\u{1b}[2J")
        return 0
    }
}

struct PatchCommand: Command {
    let name = "patch"; let usage = "patch [-p N] [-R] [-i file.diff]   (diff on stdin otherwise)"
    let summary = "apply a unified diff"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var strip = 0, reverse = false, diffText: String? = nil
        while let f = a.first {
            a.removeFirst()
            switch f {
            case "-R": reverse = true
            case "-p": guard let n = a.first.flatMap(Int.init) else { throw CommandError("-p needs a number") }; strip = n; a.removeFirst()
            case "-i": guard let p = a.first else { throw CommandError("-i needs a file") }; a.removeFirst(); diffText = try String(contentsOf: ctx.path(p), encoding: .utf8)
            default: if f.hasPrefix("-p"), let n = Int(f.dropFirst(2)) { strip = n } else if !f.hasPrefix("-") { diffText = try String(contentsOf: ctx.path(f), encoding: .utf8) } else { throw CommandError("unknown option \(f)") }
            }
        }
        guard let diff = diffText ?? ctx.stdin else { throw CommandError("no patch given") }
        let patches = PatchDiff.parse(diff)
        guard !patches.isEmpty else { throw CommandError("no hunks found") }
        var failed: Int32 = 0
        for p in patches {
            var rel = reverse ? p.oldPath : p.newPath
            if rel == "/dev/null" { rel = reverse ? p.newPath : p.oldPath }
            let parts = rel.split(separator: "/").map(String.init)
            let path = parts.dropFirst(min(strip, max(0, parts.count - 1))).joined(separator: "/")
            let url = ctx.path(path)
            let original = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            do {
                let result = try PatchDiff.apply(p, to: original, reverse: reverse)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try result.write(to: url, atomically: true, encoding: .utf8)
                ctx.print("patching file \(path)")
            } catch { ctx.printErr("patch: \(path): \(ShellSession.describe(error))"); failed = 1 }
        }
        return failed
    }
}

/// Unified diff parsing and application with a little fuzz: a hunk is placed at its stated line,
/// or at the nearest place where its context matches.
enum PatchDiff {
    struct Hunk { var oldStart: Int; var lines: [(Character, String)] }
    struct FilePatch { var oldPath: String; var newPath: String; var hunks: [Hunk] }

    static func parse(_ text: String) -> [FilePatch] {
        var out: [FilePatch] = []
        var cur: FilePatch? = nil
        var hunk: Hunk? = nil
        func flushHunk() { if let h = hunk { cur?.hunks.append(h) }; hunk = nil }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("--- ") {
                flushHunk(); if let c = cur { out.append(c) }
                cur = FilePatch(oldPath: cleanPath(String(line.dropFirst(4))), newPath: "", hunks: [])
            } else if line.hasPrefix("+++ "), cur != nil {
                cur!.newPath = cleanPath(String(line.dropFirst(4)))
            } else if line.hasPrefix("@@"), cur != nil {
                flushHunk()
                let spec = line.split(separator: " ")
                let old = spec.count > 1 ? spec[1].dropFirst() : "1"
                let start = Int(old.split(separator: ",").first ?? "1") ?? 1
                hunk = Hunk(oldStart: start, lines: [])
            } else if hunk != nil, let first = line.first, " +-\\".contains(first) {
                if first == "\\" { continue }   // "\ No newline at end of file"
                hunk!.lines.append((first, String(line.dropFirst())))
            } else if hunk != nil, line.isEmpty {
                flushHunk()   // a blank line (or the trailing newline) ends the hunk
            }
        }
        flushHunk(); if let c = cur { out.append(c) }
        return out
    }
    private static func cleanPath(_ s: String) -> String {
        var p = s.split(separator: "\t").first.map(String.init) ?? s
        if p.hasPrefix("a/") || p.hasPrefix("b/") { p = String(p.dropFirst(2)) }
        return p
    }

    static func apply(_ p: FilePatch, to text: String, reverse: Bool) throws -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var offset = 0
        for h in p.hunks {
            let before = h.lines.filter { $0.0 == " " || $0.0 == (reverse ? "+" : "-") }.map(\.1)
            let after = h.lines.filter { $0.0 == " " || $0.0 == (reverse ? "-" : "+") }.map(\.1)
            let want = max(0, h.oldStart - 1 + offset)
            guard let at = locate(before, in: lines, near: want) else { throw CommandError("hunk at line \(h.oldStart) does not apply") }
            lines.replaceSubrange(at..<(at + before.count), with: after)
            offset += after.count - before.count
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }
    private static func locate(_ pattern: [String], in lines: [String], near: Int) -> Int? {
        if pattern.isEmpty { return min(near, lines.count) }
        func matches(_ i: Int) -> Bool { i >= 0 && i + pattern.count <= lines.count && Array(lines[i..<(i + pattern.count)]) == pattern }
        if matches(near) { return near }
        for d in 1...max(1, lines.count) {
            if matches(near - d) { return near - d }
            if matches(near + d) { return near + d }
            if near - d < 0 && near + d + pattern.count > lines.count { break }
        }
        return nil
    }
}

struct SqliteCommand: Command {
    let name = "sqlite3"; let usage = "sqlite3 database.db [SQL]   (no SQL: interactive; .tables .schema .quit)"
    let summary = "SQLite shell"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let dbName = ctx.args.first else { throw CommandError("usage: \(usage)") }
        var db: OpaquePointer? = nil
        guard sqlite3_open(ctx.path(dbName).path, &db) == SQLITE_OK else { throw CommandError("cannot open \(dbName)") }
        defer { sqlite3_close(db) }
        func exec(_ sql: String) -> Bool {
            var sqlText = sql
            switch sql.trimmingCharacters(in: .whitespaces) {
            case ".tables": sqlText = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            case ".schema": sqlText = "SELECT sql FROM sqlite_master WHERE sql IS NOT NULL"
            default: break
            }
            // Statements are prepared one after another from one C buffer; `tail` points into it.
            return sqlText.withCString { base -> Bool in
                var cur: UnsafePointer<CChar> = base
                while cur.pointee != 0 {
                    var stmt: OpaquePointer? = nil
                    var tail: UnsafePointer<CChar>? = nil
                    guard sqlite3_prepare_v2(db, cur, -1, &stmt, &tail) == SQLITE_OK else {
                        ctx.printErr("Error: \(String(cString: sqlite3_errmsg(db)))"); return false
                    }
                    guard let s = stmt else { break }   // only whitespace or a comment was left
                    let n = sqlite3_column_count(s)
                    var rc = sqlite3_step(s)
                    while rc == SQLITE_ROW {
                        var row: [String] = []
                        for i in 0..<n { row.append(sqlite3_column_text(s, i).map { String(cString: $0) } ?? "") }
                        ctx.print(row.joined(separator: "|"))
                        rc = sqlite3_step(s)
                    }
                    if rc != SQLITE_DONE { ctx.printErr("Error: \(String(cString: sqlite3_errmsg(db)))"); sqlite3_finalize(s); return false }
                    sqlite3_finalize(s)
                    guard let t = tail else { break }
                    cur = t
                }
                return true
            }
        }
        if ctx.args.count > 1 { return exec(ctx.args.dropFirst().joined(separator: " ")) ? 0 : 1 }
        if let s = ctx.stdin { return exec(s) ? 0 : 1 }
        guard let raw = ctx.acquireRawInput() else { throw CommandError("no SQL given") }
        ctx.print("SQLite \(String(cString: sqlite3_libversion())) — enter SQL ending with ; or .quit")
        var it = raw.makeAsyncIterator()
        let reader = RawLineReader(ctx: ctx)
        var buf = ""
        while let line = await reader.read(prompt: buf.isEmpty ? "sqlite> " : "   ...> ", echo: true, input: &it) {
            if line == ".quit" || line == ".exit" || line == "\u{4}" { break }
            buf += line + "\n"
            if line.hasPrefix(".") || line.trimmingCharacters(in: .whitespaces).hasSuffix(";") { _ = exec(buf); buf = "" }
        }
        return 0
    }
}
