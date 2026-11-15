import Foundation
import JavaScriptCore

/// `js` / `node`: run JavaScript with the system JavaScriptCore engine (no JIT needed, App Store
/// safe since nothing is downloaded). Provides a small Node-flavoured runtime: console, require()
/// for local files and JSON, fs (sync), path, process.argv/env/exit, setTimeout/setInterval,
/// TextEncoder/Decoder, and a REPL when no file is given.
struct JSCommand: Command {
    let name = "js"; let usage = "js [file.js] [args...]  |  js -e 'code'  |  js   (REPL)"
    let summary = "run JavaScript (JavaScriptCore) with a small Node-like runtime"

    func run(_ ctx: CommandContext) async throws -> Int32 {
        let runtime = JSRuntime(ctx: ctx)
        if ctx.args.first == "-e" || ctx.args.first == "-p" {
            guard ctx.args.count > 1 else { throw CommandError("usage: \(usage)") }
            let v = runtime.evaluate(ctx.args[1], source: "<eval>")
            if ctx.args.first == "-p", let v { ctx.print(runtime.inspect(v)) }
            runtime.drainTimers()
            return runtime.exitCode
        }
        if ctx.args.first == "-v" || ctx.args.first == "--version" { ctx.print("dabterm js (JavaScriptCore) v0.1"); return 0 }
        if let file = ctx.args.first {
            let url = ctx.path(file)
            guard let src = try? String(contentsOf: url, encoding: .utf8) else { throw CommandError("cannot open \(file)") }
            runtime.argv = [url.path] + Array(ctx.args.dropFirst())
            runtime.context.setObject(runtime.argv, forKeyedSubscript: "__argv" as NSString)
            runtime.runModule(src, url: url)
            runtime.drainTimers()
            return runtime.exitCode
        }
        if let stdin = ctx.stdin {   // piped input: run it as a script, never start the REPL
            runtime.evaluate(stdin, source: "<stdin>"); runtime.drainTimers(); return runtime.exitCode
        }
        // REPL
        guard let input = ctx.acquireRawInput() else { throw CommandError("no terminal for REPL; pass a file or -e") }
        ctx.print("dabterm js REPL (JavaScriptCore) — .exit or Ctrl-D to quit")
        var iter = input.makeAsyncIterator()
        let reader = RawLineReader(ctx: ctx)
        var buffer = ""
        while true {
            guard let line = await reader.read(prompt: buffer.isEmpty ? "> " : "... ", echo: true, input: &iter) else { break }
            if line == ".exit" || line == "\u{4}" { break }
            buffer += (buffer.isEmpty ? "" : "\n") + line
            // naive multi-line: keep reading while braces are unbalanced
            let open = buffer.filter { "{([".contains($0) }.count, close = buffer.filter { "})]".contains($0) }.count
            if open > close { continue }
            if let v = runtime.evaluate(buffer, source: "<repl>"), !v.isUndefined { ctx.print(runtime.inspect(v)) }
            runtime.drainTimers()
            buffer = ""
        }
        return runtime.exitCode
    }
}

final class JSRuntime {
    let ctx: CommandContext
    let context: JSContext
    var argv: [String] = []
    var exitCode: Int32 = 0
    private var timers: [(id: Int, due: Date, fn: JSValue, interval: Double?)] = []
    private var nextTimer = 1
    private var exited = false

    init(ctx: CommandContext) {
        self.ctx = ctx
        context = JSContext()!
        context.name = "dabterm"
        context.exceptionHandler = { [weak self] _, exc in
            guard let self, let exc else { return }
            if self.exited { return }
            let stack = exc.objectForKeyedSubscript("stack")?.toString() ?? ""
            self.ctx.printErr("\u{1b}[31mUncaught \(exc)\u{1b}[0m" + (stack.isEmpty || stack == "undefined" ? "" : "\n\(stack)"))
            self.exitCode = 1
        }
        installGlobals()
    }

    @discardableResult
    func evaluate(_ code: String, source: String) -> JSValue? {
        context.evaluateScript(code, withSourceURL: URL(fileURLWithPath: source))
    }

    /// CommonJS-style module: wraps the source in a function with require/module/exports/__dirname.
    @discardableResult
    func runModule(_ src: String, url: URL) -> JSValue? {
        let wrapper = "(function(exports, require, module, __filename, __dirname) {\n\(src)\n})"
        guard let fn = context.evaluateScript(wrapper, withSourceURL: url), fn.isObject else { return nil }
        let module = JSValue(newObjectIn: context)!
        let exports = JSValue(newObjectIn: context)!
        module.setObject(exports, forKeyedSubscript: "exports" as NSString)
        let require = makeRequire(dir: url.deletingLastPathComponent())
        fn.call(withArguments: [exports, require, module, url.path, url.deletingLastPathComponent().path])
        return module.objectForKeyedSubscript("exports")
    }

    private var moduleCache: [String: JSValue] = [:]
    private func makeRequire(dir: URL) -> JSValue {
        let block: @convention(block) (String) -> JSValue? = { [weak self] name in
            guard let self else { return nil }
            if let builtin = self.builtins[name] ?? self.builtins[name.replacingOccurrences(of: "node:", with: "")] { return builtin }
            var candidates: [URL] = []
            let base = name.hasPrefix("/") ? URL(fileURLWithPath: name) : name.hasPrefix("~") ? Workspace.resolve(name, cwd: dir) : dir.appendingPathComponent(name)
            candidates += [base, base.appendingPathExtension("js"), base.appendingPathExtension("json"), base.appendingPathComponent("index.js")]
            // node_modules lookup (plain CommonJS packages only)
            var d = dir
            while d.path.count >= Workspace.root.path.count {
                let pkgDir = d.appendingPathComponent("node_modules").appendingPathComponent(name)
                if let pkgData = FileManager.default.contents(atPath: pkgDir.appendingPathComponent("package.json").path),
                   let pkg = try? JSONSerialization.jsonObject(with: pkgData) as? [String: Any], let main = pkg["main"] as? String {
                    candidates.append(pkgDir.appendingPathComponent(main)); candidates.append(pkgDir.appendingPathComponent(main).appendingPathExtension("js"))
                }
                candidates.append(pkgDir.appendingPathComponent("index.js"))
                if d.path == Workspace.root.path { break }
                d = d.deletingLastPathComponent()
            }
            for c in candidates where FileManager.default.fileExists(atPath: c.path) && !Workspace.isDirectory(c) {
                let key = c.standardizedFileURL.path
                if let cached = self.moduleCache[key] { return cached }
                guard let src = try? String(contentsOf: c, encoding: .utf8) else { continue }
                if c.pathExtension == "json" { let v = self.context.evaluateScript("(\(src))"); self.moduleCache[key] = v; return v }
                let v = self.runModule(src, url: c) ?? JSValue(undefinedIn: self.context)
                self.moduleCache[key] = v
                return v
            }
            self.context.exception = JSValue(newErrorFromMessage: "Cannot find module '\(name)'", in: self.context)
            return nil
        }
        return JSValue(object: block, in: context)
    }

    private var builtins: [String: JSValue] = [:]

    private func installGlobals() {
        let c = context
        // console
        let console = JSValue(newObjectIn: c)!
        let log: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            self.ctx.print(args.map { $0.isString ? $0.toString() : self.inspect($0) }.joined(separator: " "))
        }
        let err: @convention(block) () -> Void = { [weak self] in
            guard let self else { return }
            let args = JSContext.currentArguments() as? [JSValue] ?? []
            self.ctx.printErr(args.map { $0.isString ? $0.toString() : self.inspect($0) }.joined(separator: " "))
        }
        for k in ["log", "info", "debug", "table", "dir"] { console.setObject(log, forKeyedSubscript: k as NSString) }
        for k in ["error", "warn", "trace"] { console.setObject(err, forKeyedSubscript: k as NSString) }
        c.setObject(console, forKeyedSubscript: "console" as NSString)
        c.setObject(c.objectForKeyedSubscript("globalThis"), forKeyedSubscript: "global" as NSString)

        // process
        let process = JSValue(newObjectIn: c)!
        process.setObject(ctx.env, forKeyedSubscript: "env" as NSString)
        process.setObject("ios", forKeyedSubscript: "platform" as NSString)
        process.setObject("v0.1.0-dabterm", forKeyedSubscript: "version" as NSString)
        process.setObject(ctx.cwd.path, forKeyedSubscript: "_cwd" as NSString)
        let cwd: @convention(block) () -> String = { [ctx] in ctx.cwd.path }
        process.setObject(cwd, forKeyedSubscript: "cwd" as NSString)
        let exit: @convention(block) (Int32) -> Void = { [weak self] code in self?.exitCode = code; self?.exited = true; self?.context.exception = JSValue(newErrorFromMessage: "__exit__", in: self?.context) }
        process.setObject(exit, forKeyedSubscript: "exit" as NSString)
        let stdoutWrite: @convention(block) (String) -> Bool = { [ctx] s in ctx.out.write(s); return true }
        let stdout = JSValue(newObjectIn: c)!; stdout.setObject(stdoutWrite, forKeyedSubscript: "write" as NSString)
        process.setObject(stdout, forKeyedSubscript: "stdout" as NSString)
        let stderrWrite: @convention(block) (String) -> Bool = { [ctx] s in ctx.err.write(s); return true }
        let stderr = JSValue(newObjectIn: c)!; stderr.setObject(stderrWrite, forKeyedSubscript: "write" as NSString)
        process.setObject(stderr, forKeyedSubscript: "stderr" as NSString)
        c.setObject(process, forKeyedSubscript: "process" as NSString)
        c.evaluateScript("Object.defineProperty(process, 'argv', { get: () => ['js'].concat(globalThis.__argv || []) }); process.nextTick = f => setTimeout(f, 0); process.on = () => {};")

        // timers
        let setTimeout: @convention(block) (JSValue, Double) -> Int = { [weak self] fn, ms in self?.addTimer(fn, ms: ms, repeat: false) ?? 0 }
        let setInterval: @convention(block) (JSValue, Double) -> Int = { [weak self] fn, ms in self?.addTimer(fn, ms: ms, repeat: true) ?? 0 }
        let clear: @convention(block) (Int) -> Void = { [weak self] id in self?.timers.removeAll { $0.id == id } }
        c.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
        c.setObject(setInterval, forKeyedSubscript: "setInterval" as NSString)
        c.setObject(clear, forKeyedSubscript: "clearTimeout" as NSString)
        c.setObject(clear, forKeyedSubscript: "clearInterval" as NSString)
        c.evaluateScript("globalThis.setImmediate = f => setTimeout(f, 0); globalThis.queueMicrotask = f => setTimeout(f, 0);")

        // fs (sync subset)
        let fs = JSValue(newObjectIn: c)!
        let resolve: (String) -> URL = { [ctx] p in Workspace.resolve(p, cwd: ctx.cwd) }
        let readFile: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] p, enc in
            guard let self else { return nil }
            guard let d = FileManager.default.contents(atPath: resolve(p).path) else { self.context.exception = JSValue(newErrorFromMessage: "ENOENT: no such file or directory, open '\(p)'", in: self.context); return nil }
            if let enc, !enc.isUndefined, !enc.isNull { return JSValue(object: String(decoding: d, as: UTF8.self), in: self.context) }
            let arr = JSValue(newArrayIn: self.context)!
            for (i, b) in d.enumerated() { arr.setObject(b, atIndexedSubscript: i) }
            return arr
        }
        fs.setObject(readFile, forKeyedSubscript: "readFileSync" as NSString)
        let writeFile: @convention(block) (String, JSValue) -> Void = { [weak self] p, data in
            let url = resolve(p)
            do { if data.isString { try data.toString().write(to: url, atomically: true, encoding: .utf8) } else { try Data((data.toArray() as? [NSNumber] ?? []).map { UInt8(truncating: $0) }).write(to: url) } }
            catch { self?.context.exception = JSValue(newErrorFromMessage: "\(error.localizedDescription)", in: self?.context) }
        }
        fs.setObject(writeFile, forKeyedSubscript: "writeFileSync" as NSString)
        let appendFile: @convention(block) (String, String) -> Void = { p, s in
            let url = resolve(p); let ex = (try? String(contentsOf: url, encoding: .utf8)) ?? ""; try? (ex + s).write(to: url, atomically: true, encoding: .utf8)
        }
        fs.setObject(appendFile, forKeyedSubscript: "appendFileSync" as NSString)
        let exists: @convention(block) (String) -> Bool = { p in FileManager.default.fileExists(atPath: resolve(p).path) }
        fs.setObject(exists, forKeyedSubscript: "existsSync" as NSString)
        let readdir: @convention(block) (String) -> [String] = { p in ((try? FileManager.default.contentsOfDirectory(atPath: resolve(p).path)) ?? []).sorted() }
        fs.setObject(readdir, forKeyedSubscript: "readdirSync" as NSString)
        let mkdir: @convention(block) (String) -> Void = { p in try? FileManager.default.createDirectory(at: resolve(p), withIntermediateDirectories: true) }
        fs.setObject(mkdir, forKeyedSubscript: "mkdirSync" as NSString)
        let unlink: @convention(block) (String) -> Void = { p in try? FileManager.default.removeItem(at: resolve(p)) }
        fs.setObject(unlink, forKeyedSubscript: "unlinkSync" as NSString)
        fs.setObject(unlink, forKeyedSubscript: "rmSync" as NSString)
        let stat: @convention(block) (String) -> JSValue? = { [weak self] p in
            guard let self, let a = try? FileManager.default.attributesOfItem(atPath: resolve(p).path) else { return nil }
            let o = JSValue(newObjectIn: self.context)!
            let isDir = (a[.type] as? FileAttributeType) == .typeDirectory
            o.setObject(a[.size] ?? 0, forKeyedSubscript: "size" as NSString)
            o.setObject((a[.modificationDate] as? Date).map { $0.timeIntervalSince1970 * 1000 } ?? 0, forKeyedSubscript: "mtimeMs" as NSString)
            let isDirFn: @convention(block) () -> Bool = { isDir }; o.setObject(isDirFn, forKeyedSubscript: "isDirectory" as NSString)
            let isFileFn: @convention(block) () -> Bool = { !isDir }; o.setObject(isFileFn, forKeyedSubscript: "isFile" as NSString)
            return o
        }
        fs.setObject(stat, forKeyedSubscript: "statSync" as NSString)
        builtins["fs"] = fs
        c.setObject(fs, forKeyedSubscript: "__fs" as NSString)

        // path, os, util, events via JS
        c.evaluateScript(#"""
        globalThis.__path = {
          sep: '/', delimiter: ':',
          join: (...p) => __path.normalize(p.filter(Boolean).join('/')),
          resolve: (...p) => { let r = ''; for (const x of p) r = x.startsWith('/') ? x : (r ? r + '/' + x : x); if (!r.startsWith('/')) r = process.cwd() + '/' + r; return __path.normalize(r); },
          normalize: p => { const abs = p.startsWith('/'); const out = []; for (const s of p.split('/')) { if (!s || s === '.') continue; if (s === '..') out.pop(); else out.push(s); } return (abs ? '/' : '') + out.join('/') || (abs ? '/' : '.'); },
          basename: (p, ext) => { let b = p.split('/').filter(Boolean).pop() || ''; if (ext && b.endsWith(ext)) b = b.slice(0, -ext.length); return b; },
          dirname: p => { const s = p.split('/'); s.pop(); return s.join('/') || (p.startsWith('/') ? '/' : '.'); },
          extname: p => { const b = p.split('/').pop(); const i = b.lastIndexOf('.'); return i > 0 ? b.slice(i) : ''; },
          isAbsolute: p => p.startsWith('/'),
          relative: (a, b) => { const A = __path.resolve(a).split('/').filter(Boolean), B = __path.resolve(b).split('/').filter(Boolean); let i = 0; while (i < A.length && A[i] === B[i]) i++; return [...A.slice(i).map(() => '..'), ...B.slice(i)].join('/'); }
        };
        globalThis.__os = { platform: () => 'ios', EOL: '\n', homedir: () => process.env.HOME, tmpdir: () => process.env.HOME + '/tmp', cpus: () => [{}], arch: () => 'arm64', hostname: () => 'dabterm', type: () => 'iOS' };
        globalThis.__util = { inspect: (v) => __inspect(v), format: (f, ...a) => String(f).replace(/%[sdjo]/g, m => { const x = a.shift(); return m === '%j' ? JSON.stringify(x) : String(x); }), promisify: f => (...a) => new Promise((res, rej) => f(...a, (e, v) => e ? rej(e) : res(v))) };
        globalThis.__events = class EventEmitter { constructor(){ this._l = {}; } on(e, f){ (this._l[e] ||= []).push(f); return this; } once(e, f){ const g = (...a) => { this.off(e, g); f(...a); }; return this.on(e, g); } off(e, f){ this._l[e] = (this._l[e] || []).filter(x => x !== f); return this; } emit(e, ...a){ (this._l[e] || []).slice().forEach(f => f(...a)); return !!(this._l[e] || []).length; } };
        globalThis.__events.EventEmitter = globalThis.__events;
        globalThis.__inspect = function(v, depth = 0, seen = new Set()) {
          if (v === null) return 'null'; if (v === undefined) return 'undefined';
          const t = typeof v;
          if (t === 'string') return depth ? JSON.stringify(v) : v;
          if (t === 'number' || t === 'boolean' || t === 'bigint' || t === 'symbol') return String(v);
          if (t === 'function') return `[Function: ${v.name || 'anonymous'}]`;
          if (v instanceof Error) return v.stack || `${v.name}: ${v.message}`;
          if (v instanceof Date) return v.toISOString();
          if (v instanceof RegExp) return String(v);
          if (v instanceof Promise) return 'Promise { <pending> }';
          if (seen.has(v)) return '[Circular]'; seen.add(v);
          if (depth > 3) return Array.isArray(v) ? '[Array]' : '[Object]';
          if (Array.isArray(v)) return '[ ' + v.map(x => __inspect(x, depth + 1, seen)).join(', ') + ' ]';
          if (v instanceof Map) return 'Map { ' + [...v].map(([k, x]) => __inspect(k, depth + 1, seen) + ' => ' + __inspect(x, depth + 1, seen)).join(', ') + ' }';
          if (v instanceof Set) return 'Set { ' + [...v].map(x => __inspect(x, depth + 1, seen)).join(', ') + ' }';
          const keys = Object.keys(v); if (!keys.length) return '{}';
          return '{ ' + keys.map(k => `${/^[a-zA-Z_$][\w$]*$/.test(k) ? k : JSON.stringify(k)}: ${__inspect(v[k], depth + 1, seen)}`).join(', ') + ' }';
        };
        globalThis.TextEncoder = class { encode(s) { return new Uint8Array(unescape(encodeURIComponent(s)).split('').map(c => c.charCodeAt(0))); } };
        globalThis.TextDecoder = class { decode(b) { return decodeURIComponent(escape(String.fromCharCode(...new Uint8Array(b)))); } };
        globalThis.btoa = s => { const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; let out = '', i = 0; const b = unescape(encodeURIComponent(s)); while (i < b.length) { const a = b.charCodeAt(i++), c = b.charCodeAt(i++), d = b.charCodeAt(i++); const n = (a << 16) | ((c || 0) << 8) | (d || 0); out += chars[n >> 18] + chars[(n >> 12) & 63] + (isNaN(c) ? '=' : chars[(n >> 6) & 63]) + (isNaN(d) ? '=' : chars[n & 63]); } return out; };
        globalThis.atob = s => { const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'; let out = '', bits = 0, acc = 0; for (const ch of s.replace(/=+$/, '')) { acc = (acc << 6) | chars.indexOf(ch); bits += 6; if (bits >= 8) { bits -= 8; out += String.fromCharCode((acc >> bits) & 255); } } return decodeURIComponent(escape(out)); };
        """#)
        for (k, g) in [("path", "__path"), ("os", "__os"), ("util", "__util"), ("events", "__events")] { builtins[k] = c.objectForKeyedSubscript(g) }
        c.setObject(makeRequire(dir: ctx.cwd), forKeyedSubscript: "require" as NSString)

        // fetch (async, resolved by the timer loop)
        let fetch: @convention(block) (String, JSValue?) -> JSValue? = { [weak self] urlString, opts in
            guard let self else { return nil }
            let promiseCtor = self.context.objectForKeyedSubscript("Promise")!
            let executor: @convention(block) (JSValue, JSValue) -> Void = { resolve, reject in
                guard let url = URL(string: urlString) else { reject.call(withArguments: ["invalid url"]); return }
                var req = URLRequest(url: url)
                if let opts, opts.isObject {
                    if let m = opts.objectForKeyedSubscript("method"), m.isString { req.httpMethod = m.toString() }
                    if let h = opts.objectForKeyedSubscript("headers"), h.isObject, let d = h.toDictionary() as? [String: String] { for (k, v) in d { req.setValue(v, forHTTPHeaderField: k) } }
                    if let b = opts.objectForKeyedSubscript("body"), b.isString { req.httpBody = Data(b.toString().utf8) }
                }
                self.pendingAsync += 1
                let task = URLSession.shared.dataTask(with: req) { data, resp, error in
                    self.asyncQueue.sync {
                        self.completions.append {
                            self.pendingAsync -= 1
                            if let error { reject.call(withArguments: [error.localizedDescription]); return }
                            let http = resp as? HTTPURLResponse
                            let text = String(decoding: data ?? Data(), as: UTF8.self)
                            let res = JSValue(newObjectIn: self.context)!
                            res.setObject(http?.statusCode ?? 0, forKeyedSubscript: "status" as NSString)
                            res.setObject((http?.statusCode ?? 0) < 400, forKeyedSubscript: "ok" as NSString)
                            res.setObject(http?.allHeaderFields.reduce(into: [String: String]()) { $0[String(describing: $1.key).lowercased()] = String(describing: $1.value) } ?? [:], forKeyedSubscript: "headers" as NSString)
                            let textFn: @convention(block) () -> JSValue = { promiseCtor.invokeMethod("resolve", withArguments: [text]) }
                            let jsonFn: @convention(block) () -> JSValue = { promiseCtor.invokeMethod("resolve", withArguments: [self.context.evaluateScript("(\(text))") ?? JSValue(undefinedIn: self.context)!]) }
                            res.setObject(textFn, forKeyedSubscript: "text" as NSString)
                            res.setObject(jsonFn, forKeyedSubscript: "json" as NSString)
                            resolve.call(withArguments: [res])
                        }
                    }
                }
                task.resume()
            }
            return promiseCtor.construct(withArguments: [JSValue(object: executor, in: self.context)!])
        }
        c.setObject(fetch, forKeyedSubscript: "fetch" as NSString)
    }

    private var pendingAsync = 0
    private var completions: [() -> Void] = []
    private let asyncQueue = DispatchQueue(label: "dabterm.js.async")

    private func addTimer(_ fn: JSValue, ms: Double, repeat: Bool) -> Int {
        let id = nextTimer; nextTimer += 1
        timers.append((id, Date().addingTimeInterval(max(0, ms) / 1000), fn, `repeat` ? max(1, ms) / 1000 : nil))
        return id
    }

    /// Event loop: runs timers and network completions until nothing is pending (or Ctrl-C).
    func drainTimers() {
        while !exited {
            let ready = asyncQueue.sync { () -> [() -> Void] in let c = completions; completions = []; return c }
            for f in ready { f() }
            if timers.isEmpty && pendingAsync == 0 && ready.isEmpty { break }
            if Task.isCancelled { break }
            if let next = timers.min(by: { $0.due < $1.due }), next.due <= Date() {
                timers.removeAll { $0.id == next.id }
                if let iv = next.interval { timers.append((next.id, Date().addingTimeInterval(iv), next.fn, iv)) }
                next.fn.call(withArguments: [])
                if timers.contains(where: { $0.interval != nil }) && timers.count == 1 && pendingAsync == 0 && (ctx.out is TerminalSink) == false { break }
            } else {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
    }

    func inspect(_ v: JSValue) -> String {
        context.objectForKeyedSubscript("__inspect")?.call(withArguments: [v])?.toString() ?? v.toString()
    }
}
