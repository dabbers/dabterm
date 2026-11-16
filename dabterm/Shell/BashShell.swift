import Foundation
#if canImport(Yaegi)
import Yaegi

/// `bash`: a bash-syntax shell (mvdan/sh, pure Go, built into the Go framework) whose programs are
/// the app's commands. Pipes, functions, loops, conditionals, heredocs, globbing, `$(...)`, arrays.
/// A plain single command (no shell syntax) still runs through dsh so interactive commands such as
/// ssh and the REPLs keep the terminal's keystrokes; everything else goes through the Go shell with
/// buffered pipes. The working directory and environment are kept in sync both ways.
final class BashShell: ShellProvider {
    let name = "bash"
    let summary = "bash-syntax shell (mvdan/sh): functions, loops, $(...), heredocs, globbing"
    var isAvailable: Bool { true }
    private var shells: [ObjectIdentifier: YaegiShell] = [:]

    @MainActor
    private func shell(for session: ShellSession) throws -> YaegiShell {
        let id = ObjectIdentifier(session)
        if let s = shells[id], !s.exited() { return s }
        let exec = GoExec(session: session)
        let out = GoOutput(TerminalSink(session: session)), err = GoOutput(TerminalSink(session: session))
        var error: NSError?
        guard let s = YaegiNewShell(exec, out, err, GoInput(text: nil, next: nil), session.cwd.path, Self.envString(session.env), &error) else {
            throw CommandError("bash: \(error?.localizedDescription ?? "cannot start shell")")
        }
        shells[id] = s
        return s
    }

    private static func envString(_ env: [String: String]) -> String {
        env.filter { Int($0.key) == nil && !["?", "@"].contains($0.key) }.map { "\($0.key)=\($0.value)" }.joined(separator: "\u{0}")
    }

    /// Characters that mean "this needs a real shell"; a line without any is a plain command.
    private static let metachars: Set<Character> = ["|", ";", "&", "<", ">", "$", "(", ")", "`", "{", "}", "*", "?", "[", "~", "'", "\"", "\\", "="]
    private static func isPlain(_ line: String) -> Bool { !line.contains { metachars.contains($0) } }

    func execute(line: String, session: ShellSession) async -> Int32 {
        if Self.isPlain(line) { return await session.runDsh(line: line) }
        return await run(session: session) { $0.run(line, name: "bash") }
    }

    func execute(script: String, name: String, args: [String], session: ShellSession) async -> Int32 {
        await run(session: session) { $0.runScript(script, name: name, args: args.joined(separator: "\u{0}")) }
    }

    @MainActor
    private func run(session: ShellSession, _ body: @escaping @Sendable (YaegiShell) -> Int) async -> Int32 {
        let sh: YaegiShell
        do { sh = try shell(for: session) } catch { session.write("\(error)\n"); return 1 }
        sh.setDir(session.cwd.path)
        sh.setEnv(Self.envString(session.env))
        let code: Int = await withCheckedContinuation { cont in
            Thread.detachNewThread { cont.resume(returning: body(sh)) }
        }
        // cd inside the shell moves the session; exit ends this shell instance (a new one starts next time).
        let dir = sh.dir()
        if dir != session.cwd.path { try? session.chdir(URL(fileURLWithPath: dir)) }
        if sh.exited() { shells[ObjectIdentifier(session)] = nil }
        return Int32(code)
    }
}

/// Runs the app's commands on behalf of the Go shell. Called on the shell's thread; the command
/// itself runs in the session and the call waits for it.
final class GoExec: NSObject, YaegiExecProtocol {
    weak var session: ShellSession?
    init(session: ShellSession) { self.session = session }
    func run(_ name: String?, args: String?, __stdinp stdin: Data?, hasStdin: Bool, out_ out: YaegiOutputProtocol?, errOut: YaegiOutputProtocol?) -> Int {
        guard let session, let name else { return 127 }
        let argv = (args ?? "").isEmpty ? [] : (args ?? "").components(separatedBy: "\u{0}")
        let input = hasStdin ? String(decoding: stdin ?? Data(), as: UTF8.self) : nil
        let outSink = GoSink(out), errSink = GoSink(errOut)
        let done = DispatchSemaphore(value: 0)
        var code: Int32 = 1
        Task { @MainActor in
            code = await session.runSimple(name: name, args: argv, stdin: input, out: outSink, err: errSink)
            done.signal()
        }
        done.wait()
        return Int(code)
    }
}

/// An OutputSink that writes straight to the Go side (a pipe or the terminal, as the shell decides).
final class GoSink: OutputSink {
    let target: YaegiOutputProtocol?
    init(_ target: YaegiOutputProtocol?) { self.target = target }
    func write(_ text: String) { target?.write(Data(text.utf8)) }
}
#endif
