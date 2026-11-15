import Foundation
import Combine

/// One interactive shell bound to one terminal. Owns the line editor, history, environment
/// and the currently running command.
@MainActor
final class ShellSession: ObservableObject {
    // Terminal output sink (set by the terminal view).
    var terminal: OutputSink?
    // Called when the terminal title / cwd changes.
    @Published private(set) var cwd: URL = Workspace.home
    @Published var title: String = "dabterm"
    var env: [String: String] = [
        "HOME": Workspace.home.path, "PWD": Workspace.home.path, "USER": "dab", "SHELL": "/bin/dsh",
        "TERM": "xterm-256color", "LANG": "en_US.UTF-8", "PATH": Workspace.binDir.path, "?": "0"
    ]
    var history: [String] = []
    private var historyIndex = 0
    private var lineBuffer: [Character] = []
    private var cursor = 0
    private var runningTask: Task<Void, Never>?
    private var rawInputContinuation: AsyncStream<[UInt8]>.Continuation?
    private var pendingPrompt = false
    private var columns = 80
    private var rows = 24
    var size: (cols: Int, rows: Int) { (columns, rows) }

    let registry = CommandRegistry.shared
    /// Requests to the UI (open editor, etc.)
    var openInEditor: ((URL, Int?) -> Void)?

    static let historyURL = Workspace.root.appendingPathComponent(".dsh_history")

    init() {
        if let text = try? String(contentsOf: Self.historyURL, encoding: .utf8) {
            history = text.split(separator: "\n").map(String.init).suffix(500)
        }
        historyIndex = history.count
    }

    func start() {
        write("\u{1b}[1;36mdabterm\u{1b}[0m \u{1b}[2mv0.1 · type `help` for commands · home is the Files app folder\u{1b}[0m\r\n")
        prompt()
    }

    func resize(cols: Int, rows: Int) { columns = cols; self.rows = rows; onResize?(cols, rows) }
    var onResize: ((Int, Int) -> Void)?

    // MARK: Output
    func write(_ text: String) {
        terminal?.write(text.replacingOccurrences(of: "\n", with: "\r\n").replacingOccurrences(of: "\r\r\n", with: "\r\n"))
    }
    func writeRaw(_ text: String) { terminal?.write(text) }

    private func prompt() {
        let dir = Workspace.display(cwd)
        let status = env["?"] == "0" ? "\u{1b}[32m" : "\u{1b}[31m"
        writeRaw("\u{1b}[1;34m\(dir)\u{1b}[0m \(status)❯\u{1b}[0m ")
        lineBuffer = []; cursor = 0; historyIndex = history.count
    }

    // MARK: Input from terminal
    func feed(bytes: [UInt8]) {
        if let cont = rawInputContinuation {
            // Ctrl-C handling is up to the interactive command; ssh forwards it.
            cont.yield(bytes)
            return
        }
        if runningTask != nil {
            // Non-interactive command running: Ctrl-C cancels.
            if bytes.contains(3) { runningTask?.cancel(); write("^C\n") }
            return
        }
        guard let text = String(bytes: bytes, encoding: .utf8) else { return }
        handleLineEditing(text)
    }

    private func handleLineEditing(_ text: String) {
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let rest = text[i...]
            if c == "\u{1b}" {
                // escape sequences: arrows, home/end, delete
                if rest.hasPrefix("\u{1b}[A") { historyMove(-1); i = text.index(i, offsetBy: 3); continue }
                if rest.hasPrefix("\u{1b}[B") { historyMove(1); i = text.index(i, offsetBy: 3); continue }
                if rest.hasPrefix("\u{1b}[C") { moveCursor(1); i = text.index(i, offsetBy: 3); continue }
                if rest.hasPrefix("\u{1b}[D") { moveCursor(-1); i = text.index(i, offsetBy: 3); continue }
                if rest.hasPrefix("\u{1b}[H") || rest.hasPrefix("\u{1b}[1~") { moveCursor(-cursor); i = text.index(i, offsetBy: 3); continue }
                if rest.hasPrefix("\u{1b}[F") || rest.hasPrefix("\u{1b}[4~") { moveCursor(lineBuffer.count - cursor); i = text.index(i, offsetBy: 3); continue }
                if rest.hasPrefix("\u{1b}[3~") { if cursor < lineBuffer.count { lineBuffer.remove(at: cursor); redrawFromCursor() }; i = text.index(i, offsetBy: 4); continue }
                // alt-b / alt-f word movement
                if rest.hasPrefix("\u{1b}b") { wordMove(-1); i = text.index(i, offsetBy: 2); continue }
                if rest.hasPrefix("\u{1b}f") { wordMove(1); i = text.index(i, offsetBy: 2); continue }
                i = text.index(after: i); continue
            }
            switch c {
            case "\r", "\n": submit()
            case "\u{7f}", "\u{8}": // backspace
                if cursor > 0 { cursor -= 1; lineBuffer.remove(at: cursor); writeRaw("\u{8}"); redrawFromCursor() }
            case "\u{3}": // ctrl-c
                writeRaw("^C\r\n"); env["?"] = "130"; prompt()
            case "\u{4}": // ctrl-d
                if lineBuffer.isEmpty { write("(use `exit` or close the tab)\n"); prompt() }
            case "\u{c}": // ctrl-l
                writeRaw("\u{1b}[2J\u{1b}[H"); prompt(); writeRaw(String(lineBuffer))
            case "\u{15}": // ctrl-u
                lineBuffer.removeFirst(cursor); writeRaw("\u{1b}[\(cursor)D"); cursor = 0; redrawFromCursor()
            case "\u{b}": // ctrl-k
                lineBuffer.removeSubrange(cursor...); redrawFromCursor()
            case "\u{1}": moveCursor(-cursor) // ctrl-a
            case "\u{5}": moveCursor(lineBuffer.count - cursor) // ctrl-e
            case "\u{17}": // ctrl-w delete word
                let start = wordStart()
                let n = cursor - start
                if n > 0 { lineBuffer.removeSubrange(start..<cursor); writeRaw("\u{1b}[\(n)D"); cursor = start; redrawFromCursor() }
            case "\t": complete()
            default:
                if c.isASCII, let v = c.asciiValue, v < 32 { break }
                lineBuffer.insert(c, at: cursor); cursor += 1
                if cursor == lineBuffer.count { writeRaw(String(c)) } else { writeRaw(String(c)); redrawFromCursor() }
            }
            i = text.index(after: i)
        }
    }

    private func redrawFromCursor() {
        let tail = String(lineBuffer[cursor...])
        writeRaw("\u{1b}[K" + tail)
        if !tail.isEmpty { writeRaw("\u{1b}[\(tail.count)D") }
    }
    private func moveCursor(_ delta: Int) {
        let target = max(0, min(lineBuffer.count, cursor + delta))
        let d = target - cursor
        if d > 0 { writeRaw("\u{1b}[\(d)C") } else if d < 0 { writeRaw("\u{1b}[\(-d)D") }
        cursor = target
    }
    private func wordStart() -> Int {
        var i = cursor
        while i > 0, lineBuffer[i-1] == " " { i -= 1 }
        while i > 0, lineBuffer[i-1] != " " { i -= 1 }
        return i
    }
    private func wordMove(_ dir: Int) {
        if dir < 0 { moveCursor(wordStart() - cursor) }
        else {
            var i = cursor
            while i < lineBuffer.count, lineBuffer[i] != " " { i += 1 }
            while i < lineBuffer.count, lineBuffer[i] == " " { i += 1 }
            moveCursor(i - cursor)
        }
    }
    private func replaceLine(_ s: String) {
        if cursor > 0 { writeRaw("\u{1b}[\(cursor)D") }
        writeRaw("\u{1b}[K" + s)
        lineBuffer = Array(s); cursor = lineBuffer.count
    }
    private func historyMove(_ delta: Int) {
        let target = max(0, min(history.count, historyIndex + delta))
        historyIndex = target
        replaceLine(target == history.count ? "" : history[target])
    }

    private func complete() {
        let line = String(lineBuffer[..<cursor])
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        let partial = String(parts.last ?? "")
        var candidates: [String]
        if parts.count <= 1 {
            candidates = registry.names.filter { $0.hasPrefix(partial) }
        } else {
            let url = Workspace.resolve(partial.isEmpty ? "." : partial, cwd: cwd)
            let dir = partial.hasSuffix("/") || partial.isEmpty ? url : url.deletingLastPathComponent()
            let base = partial.hasSuffix("/") || partial.isEmpty ? "" : url.lastPathComponent
            let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            let prefix = partial.hasSuffix("/") ? partial : (partial.contains("/") ? String(partial[...partial.lastIndex(of: "/")!]) : "")
            candidates = items.filter { $0.hasPrefix(base) && (base.hasPrefix(".") || !$0.hasPrefix(".")) }
                .map { prefix + $0 + (Workspace.isDirectory(dir.appendingPathComponent($0)) ? "/" : "") }
        }
        if candidates.count == 1 {
            let add = candidates[0].dropFirst(partial.count) + (candidates[0].hasSuffix("/") ? "" : " ")
            for ch in add { lineBuffer.insert(ch, at: cursor); cursor += 1 }
            writeRaw(String(add)); redrawFromCursor()
        } else if candidates.count > 1 {
            let common = commonPrefix(candidates)
            if common.count > partial.count {
                let add = common.dropFirst(partial.count)
                for ch in add { lineBuffer.insert(ch, at: cursor); cursor += 1 }
                writeRaw(String(add)); redrawFromCursor()
            } else {
                write("\n" + Formatter.columns(candidates.sorted(), width: columns) + "\n")
                prompt(); writeRaw(String(lineBuffer)); cursor = lineBuffer.count
            }
        }
    }
    private func commonPrefix(_ s: [String]) -> String {
        guard var p = s.first else { return "" }
        for x in s.dropFirst() { while !x.hasPrefix(p) { p.removeLast() } }
        return p
    }

    // MARK: Execution
    private func submit() {
        let line = String(lineBuffer).trimmingCharacters(in: .whitespaces)
        writeRaw("\r\n")
        if line.isEmpty { prompt(); return }
        if history.last != line { history.append(line); try? (history.joined(separator: "\n") + "\n").write(to: Self.historyURL, atomically: true, encoding: .utf8) }
        run(line: line)
    }

    /// Runs a command line as if typed. Used by the UI (e.g. the SSH hosts list).
    func run(line: String) {
        runningTask = Task { [weak self] in
            guard let self else { return }
            await self.execute(line: line)
            self.runningTask = nil
            self.prompt()
        }
    }

    func execute(line: String) async {
        var expanded = line
        // bang history
        if expanded == "!!" , let last = history.dropLast().last { expanded = last; write(expanded + "\n") }
        let pipelines: [Pipeline]
        do { pipelines = try Tokenizer.parse(expanded, env: env) } catch { write("dsh: \(error)\n"); env["?"] = "2"; return }
        for p in pipelines {
            if Task.isCancelled { break }
            let code = await runPipeline(p)
            env["?"] = String(code)
        }
    }

    private func runPipeline(_ p: Pipeline) async -> Int32 {
        var stdin: String? = nil
        var code: Int32 = 0
        for (idx, stage) in p.stages.enumerated() {
            guard let name = stage.argv.first else { continue }
            let isLast = idx == p.stages.count - 1
            let sink: OutputSink = (isLast && p.redirect == nil) ? TerminalSink(session: self) : StringSink()
            let errSink = TerminalSink(session: self)
            let ctx = CommandContext(name: name, args: Array(stage.argv.dropFirst()), stdin: stdin, session: self, out: sink, err: errSink)
            if isLast && p.redirect == nil {
                let (stream, cont) = AsyncStream<[UInt8]>.makeStream()
                ctx.rawInput = stream; rawInputContinuation = nil
                ctx.rawInputProvider = { [weak self] in self?.rawInputContinuation = cont; return stream }
            }
            code = await runCommand(ctx)
            rawInputContinuation?.finish(); rawInputContinuation = nil
            if let s = sink as? StringSink { stdin = s.buffer }
        }
        if let r = p.redirect, let text = stdin {
            let url = Workspace.resolve(r.path, cwd: cwd)
            do {
                if r.append, let existing = try? String(contentsOf: url, encoding: .utf8) { try (existing + text).write(to: url, atomically: true, encoding: .utf8) }
                else { try text.write(to: url, atomically: true, encoding: .utf8) }
            } catch { write("dsh: \(r.path): \(error.localizedDescription)\n"); return 1 }
        }
        return code
    }

    private func runCommand(_ ctx: CommandContext) async -> Int32 {
        // alias / script in ~/bin
        if let cmd = registry.command(named: ctx.name) {
            do { return try await cmd.run(ctx) }
            catch is CancellationError { return 130 }
            catch let e as CommandError { ctx.printErr("\(ctx.name): \(e.message)"); return e.code }
            catch { ctx.printErr("\(ctx.name): \(Self.describe(error))"); return 1 }
        }
        let script = Workspace.binDir.appendingPathComponent(ctx.name)
        let script2 = Workspace.binDir.appendingPathComponent(ctx.name + ".sh")
        for s in [script, script2, ctx.path(ctx.name)] where FileManager.default.fileExists(atPath: s.path) && !Workspace.isDirectory(s) && (s.pathExtension == "sh" || s.path.hasPrefix(Workspace.binDir.path) || ctx.name.hasPrefix("./")) {
            return await runScript(s, args: ctx.args)
        }
        ctx.printErr("dsh: command not found: \(ctx.name)")
        return 127
    }

    func runScript(_ url: URL, args: [String]) async -> Int32 {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { write("dsh: cannot read \(url.lastPathComponent)\n"); return 1 }
        let saved = env
        for (i, a) in args.enumerated() { env[String(i + 1)] = a }
        env["0"] = url.lastPathComponent; env["@"] = args.joined(separator: " ")
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.isEmpty || l.hasPrefix("#") { continue }
            if Task.isCancelled { break }
            await execute(line: l)
        }
        let code = Int32(env["?"] ?? "0") ?? 0
        let keep = env.filter { !["0", "@"].contains($0.key) && Int($0.key) == nil }
        env = saved.merging(keep) { _, new in new }
        return code
    }

    nonisolated static func describe(_ error: Error) -> String {
        if let l = error as? LocalizedError, let d = l.errorDescription { return d }
        let ns = error as NSError
        if ns.domain.hasPrefix("dabterm") || ns.domain.hasPrefix("DabCrypto") || ns.domain.hasPrefix("Citadel") || ns.domain.hasPrefix("NIO") { return "\(error)" }
        return error.localizedDescription
    }

    func chdir(_ url: URL) throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw CommandError("no such directory: \(Workspace.display(url))") }
        env["OLDPWD"] = cwd.path
        cwd = url.standardizedFileURL
        env["PWD"] = cwd.path
        title = Workspace.display(cwd)
    }
}

/// Sink that forwards to the terminal with newline translation.
final class TerminalSink: OutputSink {
    weak var session: ShellSession?
    init(session: ShellSession) { self.session = session }
    func write(_ text: String) {
        if Thread.isMainThread { MainActor.assumeIsolated { session?.write(text) } }
        else { DispatchQueue.main.async { [session] in session?.write(text) } }
    }
}

enum Formatter {
    static func columns(_ items: [String], width: Int) -> String {
        guard let maxLen = items.map(\.count).max(), maxLen > 0 else { return "" }
        let colW = maxLen + 2
        let cols = max(1, width / colW)
        let rows = (items.count + cols - 1) / cols
        var out = ""
        for r in 0..<rows {
            var line = ""
            for c in 0..<cols {
                let i = c * rows + r
                if i < items.count { line += items[i].padding(toLength: colW, withPad: " ", startingAt: 0) }
            }
            out += line.trimmingCharacters(in: .whitespaces) + "\n"
        }
        return out
    }
    static func bytes(_ n: Int64) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var v = Double(n); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(n)" : String(format: "%.1f%@", v, units[i])
    }
}
