import Foundation

/// Output sink for a running command. Text is written in terminal style, so `\n` is
/// translated to `\r\n` on the way to the terminal.
public protocol OutputSink: AnyObject {
    func write(_ text: String)
}

final class StringSink: OutputSink {
    private(set) var buffer = ""
    func write(_ text: String) { buffer += text }
}

/// Thrown by commands for user-facing failures. The shell prints `message` and sets $? to `code`.
struct CommandError: Error, CustomStringConvertible {
    let message: String
    let code: Int32
    init(_ message: String, code: Int32 = 1) { self.message = message; self.code = code }
    var description: String { message }
}

/// Everything a command needs to run.
final class CommandContext {
    let name: String
    let args: [String]
    let stdin: String?
    let session: ShellSession
    let out: OutputSink
    let err: OutputSink
    /// Raw byte input from the terminal while this command runs (for interactive commands like ssh).
    var rawInput: AsyncStream<[UInt8]>?
    /// Interactive commands call this to take over raw terminal input (keystrokes) while they run.
    var rawInputProvider: (() -> AsyncStream<[UInt8]>)?
    func acquireRawInput() -> AsyncStream<[UInt8]>? { rawInputProvider?() }

    let cwd: URL
    let env: [String: String]

    @MainActor
    init(name: String, args: [String], stdin: String?, session: ShellSession, out: OutputSink, err: OutputSink) {
        self.name = name; self.args = args; self.stdin = stdin; self.session = session; self.out = out; self.err = err
        self.cwd = session.cwd; self.env = session.env
    }
    func path(_ s: String) -> URL { Workspace.resolve(s, cwd: cwd) }
    func print(_ s: String) { out.write(s + "\n") }
    func printErr(_ s: String) { err.write(s + "\n") }
    var isCancelled: Bool { Task.isCancelled }

    /// A context for delegating to another command with different arguments.
    func derived(name: String, args: [String], stdin: String? = nil) async -> CommandContext {
        let c = await MainActor.run { CommandContext(name: name, args: args, stdin: stdin ?? self.stdin, session: session, out: out, err: err) }
        c.rawInputProvider = rawInputProvider
        return c
    }

    /// Parses simple flags: `-abc` and `--long`. Returns (flags, positional).
    func parse(flagsWithValues: Set<String> = []) -> (flags: [String: String], positional: [String]) {
        var flags: [String: String] = [:]
        var pos: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" { pos.append(contentsOf: args[(i+1)...]); break }
            if a.hasPrefix("--"), a.count > 2 {
                let body = String(a.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    flags[String(body[..<eq])] = String(body[body.index(after: eq)...])
                } else if flagsWithValues.contains(body), i + 1 < args.count {
                    flags[body] = args[i+1]; i += 1
                } else { flags[body] = "" }
            } else if a.hasPrefix("-"), a.count > 1, Int(a) == nil {
                let letters = Array(a.dropFirst())
                for (k, ch) in letters.enumerated() {
                    let f = String(ch)
                    if flagsWithValues.contains(f) {
                        let rest = String(letters[(k+1)...])
                        if !rest.isEmpty { flags[f] = rest }
                        else if i + 1 < args.count { flags[f] = args[i+1]; i += 1 }
                        break
                    } else { flags[f] = "" }
                }
            } else { pos.append(a) }
            i += 1
        }
        return (flags, pos)
    }
}

/// A built-in shell command.
protocol Command {
    var name: String { get }
    var usage: String { get }
    var summary: String { get }
    func run(_ ctx: CommandContext) async throws -> Int32
}
