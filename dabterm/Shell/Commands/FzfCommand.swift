import Foundation

/// `fzf`: an interactive fuzzy finder in the terminal. Candidates come from stdin, or the files
/// under the current folder when nothing is piped. Type to filter, arrows (or Ctrl-J/K) to move,
/// Enter prints the choice, Esc or Ctrl-C cancels. `--history` searches the shell history and
/// `--replace` puts the choice on the prompt instead of printing it (that is what Ctrl-R does).
struct FzfCommand: Command {
    let name = "fzf"; let usage = "fzf [--query text] [--history] [--replace]   (stdin lines, else files under .)"
    let summary = "fuzzy finder: pick a line, file or history entry interactively"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        var a = ctx.args
        var query = "", fromHistory = false, replace = false
        while let f = a.first {
            a.removeFirst()
            switch f {
            case "--query", "-q": query = a.isEmpty ? "" : a.removeFirst()
            case "--history": fromHistory = true
            case "--replace": replace = true
            default: break
            }
        }
        let items: [String]
        if fromHistory { items = Array(await ctx.session.history.reversed()).uniqued() }
        else if let s = ctx.stdin { items = s.split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
        else { items = Self.files(under: ctx.cwd) }
        guard !items.isEmpty else { return 1 }
        guard let raw = ctx.acquireRawInput() else {
            // Not interactive: behave like a filter.
            for m in Fuzzy.rank(items, query) { ctx.print(m) }
            return 0
        }
        let (cols, rows) = await ctx.session.size
        let pick = await FzfPicker(items: items, query: query, cols: cols, rows: rows, out: ctx.out).run(raw)
        ctx.out.write("\u{1b}[H\u{1b}[2J")
        guard let pick else { return 130 }
        if replace { await MainActor.run { ctx.session.pendingLine = pick } } else { ctx.print(pick) }
        return 0
    }

    static func files(under dir: URL, limit: Int = 20000) -> [String] {
        var out: [String] = []
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        let base = dir.standardizedFileURL.path + "/"
        for case let u as URL in e {
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            out.append(String(u.standardizedFileURL.path.dropFirst(base.count)))
            if out.count >= limit { break }
        }
        return out
    }
}

enum Fuzzy {
    /// Subsequence match with a score: consecutive matches and word starts score higher, shorter
    /// candidates win ties. Case-insensitive unless the query has an uppercase letter.
    static func score(_ candidate: String, _ query: String) -> Int? {
        if query.isEmpty { return 0 }
        let smart = query.contains { $0.isUppercase }
        let c = Array(smart ? candidate : candidate.lowercased()), q = Array(smart ? query : query.lowercased())
        var qi = 0, score = 0, last = -2
        for (i, ch) in c.enumerated() where qi < q.count && ch == q[qi] {
            score += 10
            if i == last + 1 { score += 15 }
            if i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber) { score += 10 }
            last = i; qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 100 - c.count
    }
    static func rank(_ items: [String], _ query: String) -> [String] {
        if query.isEmpty { return items }
        return items.compactMap { s in score(s, query).map { (s, $0) } }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// The interactive list: a prompt line at the top, matches below, the selection highlighted.
@MainActor
final class FzfPicker {
    let items: [String]
    var query: String
    let cols: Int, rows: Int
    let out: OutputSink
    var matches: [String] = []
    var selected = 0
    init(items: [String], query: String, cols: Int, rows: Int, out: OutputSink) {
        self.items = items; self.query = query; self.cols = cols; self.rows = rows; self.out = out
        refilter()
    }
    func refilter() { matches = Fuzzy.rank(items, query); selected = 0 }
    func draw() {
        let visible = max(1, rows - 2)
        let start = max(0, min(selected - visible / 2, matches.count - visible))
        // No newline after the last row: one more would scroll the prompt line off the top.
        var rowsOut = ["> \(query)\u{1b}[K", "\u{1b}[2m  \(matches.count)/\(items.count)\u{1b}[0m"]
        for i in start..<min(start + visible, matches.count) {
            let line = String(matches[i].prefix(cols - 2))
            rowsOut.append(i == selected ? "\u{1b}[7m> \(line)\u{1b}[0m" : "  \(line)")
        }
        out.write("\u{1b}[H\u{1b}[2J" + rowsOut.joined(separator: "\n") + "\u{1b}[1;\(3 + query.count)H")
    }
    func run(_ raw: AsyncStream<[UInt8]>) async -> String? {
        draw()
        var pending: [UInt8] = []
        for await bytes in raw {
            for b in bytes {
                if !pending.isEmpty {
                    pending.append(b)
                    if pending.count < 3 { continue }
                    switch pending { case [27, 91, 65]: up(); case [27, 91, 66]: down(); default: break }
                    pending = []; draw(); continue
                }
                switch b {
                case 13, 10: return matches.isEmpty ? nil : matches[selected]
                case 3, 7: return nil
                case 27: pending = [27]; continue
                case 127, 8: if !query.isEmpty { query.removeLast(); refilter() }
                case 10 + 4, 16: up()        // Ctrl-N? no: Ctrl-P (16) up
                case 14: down()               // Ctrl-N down
                case 11: up()                 // Ctrl-K
                case 21: query = ""; refilter()
                default: if b >= 32 { query.append(Character(UnicodeScalar(b))); refilter() }
                }
                draw()
            }
            // A lone Esc (no sequence followed) cancels.
            if pending == [27] { return nil }
        }
        return nil
    }
    private func up() { selected = max(0, selected - 1) }
    private func down() { selected = min(max(0, matches.count - 1), selected + 1) }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] { var seen = Set<Element>(); return filter { seen.insert($0).inserted } }
}
