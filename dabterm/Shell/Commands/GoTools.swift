import Foundation
#if canImport(Yaegi)
import Yaegi

/// Developer tools that live in the Go framework (gobridge/tools_native.go): awk, a real jq, yq,
/// gofmt, tar, zip, unzip, gzip. Present only in builds that bundle the framework.
enum GoTools {
    static var all: [Command] { [AwkCommand(), GoJqCommand(), YqCommand(), GofmtCommand(), TarCommand(), ZipCommand(), UnzipCommand(), GzipCommand()] }

    /// stdin for a Go tool: piped text, else nothing (EOF).
    static func input(_ ctx: CommandContext) -> GoInput { GoInput(text: ctx.stdin, next: nil) }

    /// Reads the named files, or stdin when there are none.
    static func text(_ ctx: CommandContext, _ files: [String]) throws -> String {
        if files.isEmpty { return ctx.stdin ?? "" }
        var out = ""
        for f in files {
            guard let d = FileManager.default.contents(atPath: ctx.path(f).path) else { throw CommandError("\(f): No such file or directory") }
            out += String(decoding: d, as: UTF8.self)
        }
        return out
    }
}

struct AwkCommand: Command {
    let name = "awk"; let usage = "awk [-F fs] [-v var=value] 'program' [file...]  |  awk -f prog.awk [file...]"
    let summary = "AWK (goawk): pattern scanning and text processing"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var vars: [String] = []
        var prog: String? = nil
        while let f = a.first, f.hasPrefix("-"), f != "--" {
            a.removeFirst()
            switch f {
            case "-F": guard !a.isEmpty else { throw CommandError("usage: \(usage)") }; vars.append("FS=" + a.removeFirst())
            case "-v": guard !a.isEmpty else { throw CommandError("usage: \(usage)") }; vars.append(a.removeFirst())
            case "-f": guard !a.isEmpty else { throw CommandError("usage: \(usage)") }
                guard let s = try? String(contentsOf: ctx.path(a.removeFirst()), encoding: .utf8) else { throw CommandError("cannot read program file") }
                prog = s
            default:
                if f.hasPrefix("-F") { vars.append("FS=" + String(f.dropFirst(2))) }
                else if f.hasPrefix("-v") { vars.append(String(f.dropFirst(2))) }
                else { throw CommandError("unknown option \(f)") }
            }
        }
        if a.first == "--" { a.removeFirst() }
        if prog == nil { guard !a.isEmpty else { throw CommandError("usage: \(usage)") }; prog = a.removeFirst() }
        let files = a.map { $0.contains("=") && !FileManager.default.fileExists(atPath: ctx.path($0).path) ? $0 : ctx.path($0).path }
        let out = GoOutput(ctx.out), err = GoOutput(ctx.err)
        let input = GoTools.input(ctx)
        let p = prog!, argv = files.joined(separator: "\u{0}"), v = vars.joined(separator: "\u{0}"), cwd = ctx.cwd.path
        return Int32(await offMain { YaegiAwk(p, argv, v, input, out, err, cwd) })
    }
}

/// jq on gojq: the full language. Replaces the path-only jq when the Go framework is bundled.
struct GoJqCommand: Command {
    let name = "jq"; let usage = "jq [-r] [-c] [filter] [file...]"
    let summary = "query and transform JSON (full jq language)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var raw = false, compact = false
        while let f = a.first, f.hasPrefix("-"), f != "--" {
            a.removeFirst()
            for c in f.dropFirst() { switch c { case "r": raw = true; case "c": compact = true; default: throw CommandError("unknown option -\(c)") } }
        }
        if a.first == "--" { a.removeFirst() }
        let filter = a.isEmpty ? "." : a.removeFirst()
        let text = try GoTools.text(ctx, a)
        var e: NSError?
        let result = YaegiJq(filter, text, false, false, raw, compact, &e)
        ctx.out.write(result)
        if let e { throw CommandError(e.localizedDescription) }
        return 0
    }
}

struct YqCommand: Command {
    let name = "yq"; let usage = "yq [-o json|yaml] [-r] [filter] [file...]"
    let summary = "query and transform YAML with jq filters"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var raw = false, json = false
        while let f = a.first, f.hasPrefix("-"), f != "--" {
            a.removeFirst()
            switch f {
            case "-r": raw = true
            case "-o": guard !a.isEmpty else { throw CommandError("usage: \(usage)") }; json = a.removeFirst() == "json"
            case "-j": json = true
            default: throw CommandError("unknown option \(f)")
            }
        }
        if a.first == "--" { a.removeFirst() }
        let filter = a.isEmpty ? "." : a.removeFirst()
        let text = try GoTools.text(ctx, a)
        var e: NSError?
        let result = YaegiJq(filter, text, true, !json, raw, false, &e)
        ctx.out.write(result)
        if let e { throw CommandError(e.localizedDescription) }
        return 0
    }
}

struct GofmtCommand: Command {
    let name = "gofmt"; let usage = "gofmt [-w] [-l] [file...]   (no files: stdin)"
    let summary = "format Go source"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var write = false, list = false
        while let f = a.first, f.hasPrefix("-") { a.removeFirst(); switch f { case "-w": write = true; case "-l": list = true; default: throw CommandError("unknown option \(f)") } }
        if a.isEmpty {
            var e: NSError?
            let out = YaegiGofmt(ctx.stdin ?? "", &e)
            if let e { throw CommandError(e.localizedDescription) }
            ctx.out.write(out); return 0
        }
        var status: Int32 = 0
        for f in a {
            let url = ctx.path(f)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { ctx.printErr("\(f): cannot read"); status = 1; continue }
            var e: NSError?
            let out = YaegiGofmt(src, &e)
            if let e { ctx.printErr("\(f): \(e.localizedDescription)"); status = 1; continue }
            if out != src, list { ctx.print(f) }
            if write { if out != src { try out.write(to: url, atomically: true, encoding: .utf8) } }
            else if !list { ctx.out.write(out) }
        }
        return status
    }
}

struct TarCommand: Command {
    let name = "tar"; let usage = "tar -czf out.tgz files...  |  tar -xzf in.tgz [-C dir]  |  tar -tf in.tar"
    let summary = "create, extract or list tar archives (gzip with z)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var op = "", gz = false, verbose = false, archive: String? = nil, dest = ctx.cwd.path
        // Flags: a first bundle like czf / -xzf / --create, then -C dir anywhere.
        guard let first = a.first else { throw CommandError("usage: \(usage)") }
        a.removeFirst()
        for c in first.trimmingCharacters(in: CharacterSet(charactersIn: "-")) {
            switch c {
            case "c", "x", "t": op = String(c)
            case "z": gz = true
            case "v": verbose = true
            case "f": break
            default: throw CommandError("unknown flag \(c)")
            }
        }
        guard !op.isEmpty else { throw CommandError("one of c, x, t is required") }
        if first.contains("f") { guard !a.isEmpty else { throw CommandError("f needs an archive name") }; archive = a.removeFirst() }
        if let i = a.firstIndex(of: "-C"), i + 1 < a.count { dest = ctx.path(a[i + 1]).path; a.removeSubrange(i...(i + 1)) }
        guard let archive else { throw CommandError("archive name required (f)") }
        if op == "c" && a.isEmpty { throw CommandError("nothing to archive") }
        if op == "c" && !gz && (archive.hasSuffix(".tgz") || archive.hasSuffix(".tar.gz")) { gz = true }
        let out = GoOutput(ctx.out)
        let arch = ctx.path(archive).path, files = a.joined(separator: "\u{0}"), cwd = ctx.cwd.path, o = op, g = gz, v = verbose, d = dest
        let err: NSError? = await offMain {
            var e: NSError?
            YaegiTar(o, arch, files, cwd, d, g, v, out, &e)
            return e
        }
        if let err { throw CommandError(err.localizedDescription) }
        return 0
    }
}

struct ZipCommand: Command {
    let name = "zip"; let usage = "zip [-r] out.zip files..."
    let summary = "create a zip archive"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var verbose = false
        while let f = a.first, f.hasPrefix("-") { a.removeFirst(); if f.contains("v") { verbose = true } }
        guard a.count >= 2 else { throw CommandError("usage: \(usage)") }
        let archive = ctx.path(a.removeFirst()).path
        let out = GoOutput(ctx.out)
        let files = a.joined(separator: "\u{0}"), cwd = ctx.cwd.path, v = verbose
        let err: NSError? = await offMain { var e: NSError?; YaegiZip(archive, files, cwd, v, out, &e); return e }
        if let err { throw CommandError(err.localizedDescription) }
        return 0
    }
}

struct UnzipCommand: Command {
    let name = "unzip"; let usage = "unzip [-l] file.zip [-d dir]"
    let summary = "extract or list a zip archive"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var list = false, dest = ctx.cwd.path
        if a.first == "-l" { list = true; a.removeFirst() }
        if let i = a.firstIndex(of: "-d"), i + 1 < a.count { dest = ctx.path(a[i + 1]).path; a.removeSubrange(i...(i + 1)) }
        guard let f = a.first else { throw CommandError("usage: \(usage)") }
        let archive = ctx.path(f).path
        let out = GoOutput(ctx.out)
        let l = list, d = dest
        let err: NSError? = await offMain { var e: NSError?; YaegiUnzip(archive, d, l, out, &e); return e }
        if let err { throw CommandError(err.localizedDescription) }
        return 0
    }
}

struct GzipCommand: Command {
    let name = "gzip"; let usage = "gzip [-d] [-k] file...   (gunzip = gzip -d)"
    let summary = "compress or decompress files with gzip"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var decompress = ctx.name == "gunzip", keep = false
        while let f = a.first, f.hasPrefix("-") { a.removeFirst(); for c in f.dropFirst() { switch c { case "d": decompress = true; case "k": keep = true; default: throw CommandError("unknown option -\(c)") } } }
        guard !a.isEmpty else { throw CommandError("usage: \(usage)") }
        for f in a {
            let p = ctx.path(f).path, d = decompress, k = keep
            let err: NSError? = await offMain { var e: NSError?; YaegiGzip(p, d, k, &e); return e }
            if let err { throw CommandError(err.localizedDescription) }
        }
        return 0
    }
}

/// Go calls block; run them off the main actor.
private func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { cont in Thread.detachNewThread { cont.resume(returning: work()) } }
}
#endif
