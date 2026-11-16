import Foundation
#if canImport(Python)
import Python
#endif

/// `python` / `python3`: embedded CPython 3.13 (the official iOS build from BeeWare's
/// Python-Apple-support, see scripts/fetch-python.sh). One interpreter per process, so scripts
/// run one at a time on a dedicated thread; each run gets a fresh __main__, its own sys.argv and
/// stdout/stderr/stdin pipes wired to the shell.
struct PythonCommand: Command {
    let name = "python"; let usage = "python [-c code | -m module | file.py] [args...]   (no args: REPL)"
    let summary = "run Python 3.13 (bundled CPython)"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        #if canImport(Python)
        guard PythonRuntime.isAvailable else { throw CommandError(PythonRuntime.unavailableReason) }
        return try await PythonRuntime.shared.run(args: ctx.args, ctx: ctx)
        #else
        throw CommandError("Python is not bundled in this build. Run scripts/fetch-python.sh, then xcodegen generate and rebuild.")
        #endif
    }
}

#if canImport(Python)
final class PythonRuntime {
    static let shared = PythonRuntime()
    private let queue = DispatchQueue(label: "dabterm.python")
    private var initialized = false
    private var initError: String?

    static var stdlibRoot: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("python/lib/python3.13")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
    static var isAvailable: Bool { stdlibRoot != nil }
    static var unavailableReason: String { "Python standard library missing from the app bundle (build phase scripts/install-python-stdlib.sh did not run)" }

    private func initializeIfNeeded() -> String? {
        if initialized { return initError }
        initialized = true
        guard let lib = Self.stdlibRoot else { initError = Self.unavailableReason; return initError }
        try? FileManager.default.createDirectory(at: Workspace.root.appendingPathComponent("site-packages"), withIntermediateDirectories: true)
        var config = PyConfig()
        PyConfig_InitIsolatedConfig(&config)
        defer { PyConfig_Clear(&config) }
        config.install_signal_handlers = 0
        config.buffered_stdio = 0
        config.write_bytecode = 0
        config.use_environment = 0
        config.module_search_paths_set = 1
        let home = lib.deletingLastPathComponent().deletingLastPathComponent().path   // <app>/python
        let status: PyStatus = withUnsafeMutablePointer(to: &config) { cfg in
            _ = home.withCString { PyConfig_SetBytesString(cfg, &cfg.pointee.home, $0) }
            _ = "python".withCString { PyConfig_SetBytesString(cfg, &cfg.pointee.program_name, $0) }
            for p in [lib.path, lib.appendingPathComponent("lib-dynload").path, Workspace.root.appendingPathComponent("site-packages").path] {
                _ = p.withCString { PyWideStringList_Append(&cfg.pointee.module_search_paths, Py_DecodeLocale($0, nil)) }
            }
            return Py_InitializeFromConfig(cfg)
        }
        if PyStatus_Exception(status) != 0 {
            initError = "Python failed to initialize: \(status.err_msg.map { String(cString: $0) } ?? "unknown")"
            return initError
        }
        // bootstrap: a helper that runs one command with redirected stdio and reports the exit code
        let bootstrap = """
        import sys, os, io, runpy, traceback, code, builtins, importlib
        def _dab_run(mode, target, argv, out_fd, err_fd, in_fd, cwd):
            importlib.invalidate_caches()   # packages installed by pip since the last run
            # UTF-8 explicitly: the process locale is C, so the default would be ASCII and the
            # first non-ASCII character (the REPL banner has one) would raise UnicodeEncodeError.
            out = os.fdopen(out_fd, 'w', buffering=1, closefd=False, encoding='utf-8', errors='replace')
            err = os.fdopen(err_fd, 'w', buffering=1, closefd=False, encoding='utf-8', errors='replace')
            inp = os.fdopen(in_fd, 'r', buffering=1, closefd=False, encoding='utf-8', errors='replace')
            saved = (sys.stdout, sys.stderr, sys.stdin, sys.argv, list(sys.path))
            sys.stdout, sys.stderr, sys.stdin = out, err, inp
            os.chdir(cwd)
            if cwd not in sys.path: sys.path.insert(0, cwd)
            rc = 0
            try:
                if mode == 'file':
                    sys.argv = [target] + argv
                    runpy.run_path(target, run_name='__main__')
                elif mode == 'module':
                    sys.argv = [target] + argv
                    runpy.run_module(target, run_name='__main__', alter_sys=True)
                elif mode == 'code':
                    sys.argv = ['-c'] + argv
                    exec(compile(target, '<string>', 'exec'), {'__name__': '__main__', '__builtins__': builtins})
                elif mode == 'repl':
                    sys.argv = ['']
                    code.interact(banner=target, local={'__name__': '__main__'}, exitmsg='')
            except SystemExit as e:
                rc = e.code if isinstance(e.code, int) else (0 if e.code is None else 1)
                if isinstance(e.code, str): print(e.code, file=err)
            except KeyboardInterrupt:
                print('KeyboardInterrupt', file=err); rc = 130
            except BaseException:
                traceback.print_exc(file=err); rc = 1
            finally:
                try: out.flush(); err.flush()
                except Exception: pass
                sys.stdout, sys.stderr, sys.stdin, sys.argv, sys.path[:] = saved
            return rc
        """
        if PyRun_SimpleString(bootstrap) != 0 { initError = "Python bootstrap failed"; return initError }
        // Release the GIL held by the initializing thread; each run re-acquires it with
        // PyGILState_Ensure, which works from whichever thread the serial queue uses.
        PyEval_SaveThread()
        return nil
    }

    func run(args: [String], ctx: CommandContext) async throws -> Int32 {
        var mode = "file", target = "", rest: [String] = []
        var a = args
        if a.first == "--version" || a.first == "-V" { ctx.print("Python \(Self.version)"); return 0 }
        if a.first == "-c", a.count > 1 { mode = "code"; target = a[1]; rest = Array(a.dropFirst(2)) }
        else if a.first == "-m", a.count > 1 { mode = "module"; target = a[1]; rest = Array(a.dropFirst(2)) }
        else if let f = a.first, !f.hasPrefix("-") { target = ctx.path(f).path; rest = Array(a.dropFirst()) }
        else if a.first == "-" || a.isEmpty, let s = ctx.stdin { mode = "code"; target = s }
        else if a.isEmpty { mode = "repl"; target = "Python \(Self.version) on iOS (dabterm) — Ctrl-D or exit() to quit" }
        else { while let f = a.first, f.hasPrefix("-") { a.removeFirst() }; guard let f = a.first else { throw CommandError("usage: python [-c code | -m module | file.py] [args...]") }; target = ctx.path(f).path; rest = Array(a.dropFirst()) }

        var out: [Int32] = [0, 0], err: [Int32] = [0, 0], inp: [Int32] = [0, 0]
        guard pipe(&out) == 0, pipe(&err) == 0, pipe(&inp) == 0 else { throw CommandError("pipe failed") }
        let pump = PipePump(fds: [(out[0], ctx.out), (err[0], ctx.err)])
        pump.start()
        // stdin: piped text, else keystrokes from the terminal while the script runs (input()/REPL)
        var inputTask: Task<Void, Never>? = nil
        if let s = ctx.stdin, mode != "repl" { _ = s.withCString { write(inp[1], $0, strlen($0)) }; close(inp[1]) }
        else if let raw = ctx.acquireRawInput() {
            let wfd = inp[1]
            inputTask = Task {
                var iter = raw.makeAsyncIterator()
                let reader = RawLineReader(ctx: ctx)
                while let line = await reader.read(prompt: "", echo: true, input: &iter) {
                    if line == "\u{4}" { break }
                    _ = (line + "\n").withCString { write(wfd, $0, strlen($0)) }
                }
                close(wfd)
            }
        } else { close(inp[1]) }

        let cwd = ctx.cwd.path
        let code: Int32 = try await withCheckedThrowingContinuation { cont in
            queue.async {
                defer { close(out[1]); close(err[1]); close(inp[0]) }
                if let e = self.initializeIfNeeded() { cont.resume(throwing: CommandError(e)); return }
                let gil = PyGILState_Ensure()
                defer { PyGILState_Release(gil) }
                let main = PyImport_AddModule("__main__")
                let dict = PyModule_GetDict(main)
                guard let fn = PyDict_GetItemString(dict, "_dab_run") else { cont.resume(throwing: CommandError("python bootstrap missing")); return }
                let argv = PyList_New(rest.count)
                for (i, s) in rest.enumerated() { PyList_SetItem(argv, i, PyUnicode_FromString(s)) }
                let pyArgs = PyTuple_New(7)
                PyTuple_SetItem(pyArgs, 0, PyUnicode_FromString(mode))
                PyTuple_SetItem(pyArgs, 1, PyUnicode_FromString(target))
                PyTuple_SetItem(pyArgs, 2, argv)
                PyTuple_SetItem(pyArgs, 3, PyLong_FromLong(Int(out[1])))
                PyTuple_SetItem(pyArgs, 4, PyLong_FromLong(Int(err[1])))
                PyTuple_SetItem(pyArgs, 5, PyLong_FromLong(Int(inp[0])))
                PyTuple_SetItem(pyArgs, 6, PyUnicode_FromString(cwd))
                let result = PyObject_CallObject(fn, pyArgs)
                Py_DecRef(pyArgs)
                var rc: Int32 = 1
                if let result { rc = Int32(PyLong_AsLong(result)); Py_DecRef(result) } else { PyErr_Print() }
                cont.resume(returning: rc)
            }
        }
        inputTask?.cancel()
        pump.finish()
        return code
    }

    static var version: String {
        let v = String(cString: Py_GetVersion())
        return String(v.split(separator: " ").first ?? "3.13")
    }

    /// Ctrl-C: ask the interpreter to raise KeyboardInterrupt.
    func interrupt() { PyErr_SetInterrupt() }
}
#endif
