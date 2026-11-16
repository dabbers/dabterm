import Foundation
#if canImport(Yaegi)
import Yaegi
#endif

/// `go`: Go on the phone through Yaegi, a Go interpreter written in Go and built into the app with
/// gomobile (gobridge/, scripts/build-go.sh). No compiler and no JIT, which is what Apple allows;
/// the standard library is compiled in. `go run file.go [args]`, `go file.go`, piped source, or a
/// REPL. Importable source packages go under ~/go/src.
struct GoCommand: Command {
    let name = "go"; let usage = "go [run] file.go [args...]   |   go -e 'code'   |   go   (REPL)"
    let summary = "run Go source (Yaegi interpreter)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        #if canImport(Yaegi)
        return try await GoRuntime.run(args: ctx.args, ctx: ctx)
        #else
        throw CommandError("Go is not bundled in this build. Run scripts/build-go.sh, then xcodegen generate and rebuild.")
        #endif
    }
}

#if canImport(Yaegi)
/// Bridges the shell's streams to the interpreter: stdout/stderr land in the sinks directly,
/// stdin is either the piped text or keystrokes read line by line from the terminal.
final class GoOutput: NSObject, YaegiOutputProtocol {
    let sink: OutputSink
    init(_ sink: OutputSink) { self.sink = sink }
    func write(_ data: Data?) { if let data { sink.write(String(decoding: data, as: UTF8.self)) } }
}

final class GoInput: NSObject, YaegiInputProtocol {
    private var buffer: [UInt8]
    private let next: (() -> String?)?
    private var done = false
    init(text: String?, next: (() -> String?)?) { buffer = Array((text ?? "").utf8); self.next = next }
    func read(_ max: Int) throws -> Data {
        if buffer.isEmpty, !done {
            if let next, let line = next() { buffer = Array((line + "\n").utf8) } else { done = true }
        }
        let n = min(max, buffer.count)
        let out = Data(buffer[0..<n]); buffer.removeFirst(n)
        return out
    }
}

enum GoRuntime {
    static let version = "yaegi (Go 1.21 semantics)"

    static func run(args: [String], ctx: CommandContext) async throws -> Int32 {
        var a = args
        if a.first == "version" || a.first == "--version" { ctx.print("go: \(version), interpreted"); return 0 }
        if a.first == "run" { a.removeFirst() }
        let goPath = Workspace.root.appendingPathComponent("go").path
        // os.Args: the program (the file, or "go" for snippets) followed by its own arguments.
        let rest = a.first.map { $0.hasPrefix("-") ? Array(a.dropFirst(2)) : Array(a.dropFirst()) } ?? []
        let argv = ([a.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "go"] + rest).joined(separator: "\u{0}")
        let out = GoOutput(ctx.out), err = GoOutput(ctx.err)

        // Source from -e, a file, or piped text.
        if a.first == "-e", a.count > 1 {
            let interp = YaegiNew(out, err, GoInput(text: ctx.stdin, next: nil), argv, goPath, ctx.cwd.path)!
            let src = wrap(a[1])
            let rc: Int = await offMain { interp.runSource(src, errOut: err) }
            return Int32(rc)
        }
        if let f = a.first, !f.hasPrefix("-") {
            let url = ctx.path(f)
            guard FileManager.default.fileExists(atPath: url.path) else { throw CommandError("\(f): no such file") }
            return await runInteractive(ctx: ctx, mode: .file(url.path), argv: argv, goPath: goPath, out: out, err: err)
        }
        if let s = ctx.stdin {
            let interp = YaegiNew(out, err, GoInput(text: nil, next: nil), argv, goPath, ctx.cwd.path)!
            let rc: Int = await offMain { interp.runSource(s, errOut: err) }
            return Int32(rc)
        }
        return await runInteractive(ctx: ctx, mode: .repl, argv: argv, goPath: goPath, out: out, err: err)
    }

    private enum Mode { case file(String), repl }

    /// Programs may read stdin and the REPL needs lines: both take over the terminal's keystrokes.
    private static func runInteractive(ctx: CommandContext, mode: Mode, argv: String, goPath: String, out: GoOutput, err: GoOutput) async -> Int32 {
        // Keystrokes arrive on an async stream; the interpreter's blocking Read needs a synchronous
        // line source, so pump lines through a small mailbox.
        let box = LineBox()
        var pump: Task<Void, Never>? = nil
        // Piped text is the whole of stdin; only without it do keystrokes feed the program.
        if ctx.stdin != nil, case .file = mode { box.close() }
        else if let raw = ctx.acquireRawInput() {
            pump = Task {
                var iter = raw.makeAsyncIterator()
                let reader = RawLineReader(ctx: ctx)
                while let line = await reader.read(prompt: "", echo: true, input: &iter) {
                    if line == "\u{4}" { break }
                    box.push(line)
                }
                box.close()
            }
        } else { box.close() }
        defer { pump?.cancel() }
        let input = GoInput(text: ctx.stdin, next: { box.pop() })
        let interp = YaegiNew(out, err, input, argv, goPath, ctx.cwd.path)!
        switch mode {
        case .file(let path):
            let rc: Int = await offMain { interp.runFile(path, errOut: err) }
            return Int32(rc)
        case .repl:
            ctx.print("Go REPL (\(version)) — expressions print their value; Ctrl-D to quit")
            var pending = ""
            while true {
                ctx.out.write(pending.isEmpty ? "> " : ". ")
                guard let line = await box.popAsync() else { break }
                pending += (pending.isEmpty ? "" : "\n") + line
                if YaegiIncomplete(pending) { continue }
                let src = pending; pending = ""
                if src.trimmingCharacters(in: .whitespaces).isEmpty { continue }
                let result: Result<String, Error> = await offMain {
                    var e: NSError?
                    let v = interp.eval(src, error: &e)
                    if let e { return .failure(e) }
                    return .success(v)
                }
                switch result {
                case .success(let v): if !v.isEmpty { ctx.print(v) }
                case .failure(let e): ctx.printErr(e.localizedDescription)
                }
            }
            ctx.out.write("\n")
            return 0
        }
    }

    /// Yaegi runs on a background thread; the shell's sinks are thread-safe.
    private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { cont in
            Thread.detachNewThread { cont.resume(returning: work()) }
        }
    }

    /// `go -e 'fmt.Println(1)'`: wrap a snippet into a main package if it is not one already, with
    /// the usual packages imported (unused ones are referenced so the compiler does not object).
    static let snippetImports = ["fmt", "os", "io", "bufio", "strings", "strconv", "math", "time", "sort", "errors", "bytes", "regexp", "encoding/json"]
    private static func wrap(_ code: String) -> String {
        if code.contains("package ") { return code }
        let imports = snippetImports.map { "\t\"\($0)\"" }.joined(separator: "\n")
        let refs = ["fmt.Sprint", "os.Getenv", "io.EOF", "bufio.NewReader", "strings.TrimSpace", "strconv.Itoa", "math.Pi", "time.Now",
                    "sort.Ints", "errors.New", "bytes.NewReader", "regexp.QuoteMeta", "json.Valid"].map { "var _ = \($0)" }.joined(separator: "\n")
        return "package main\nimport (\n\(imports)\n)\n\(refs)\nfunc main() {\n\(code)\n}\n"
    }
}

/// Lines from the terminal, handed to a blocking reader on another thread.
final class LineBox: @unchecked Sendable {
    private var lines: [String] = []
    private var closed = false
    private let lock = NSCondition()
    func push(_ s: String) { lock.lock(); lines.append(s); lock.broadcast(); lock.unlock() }
    func close() { lock.lock(); closed = true; lock.broadcast(); lock.unlock() }
    /// Blocks until a line is available (nil once closed and drained).
    func pop() -> String? {
        lock.lock(); defer { lock.unlock() }
        while lines.isEmpty && !closed { lock.wait() }
        return lines.isEmpty ? nil : lines.removeFirst()
    }
    /// Same, but off the calling actor so the REPL loop does not block the shell.
    func popAsync() async -> String? {
        await withCheckedContinuation { cont in Thread.detachNewThread { cont.resume(returning: self.pop()) } }
    }
}
#endif
