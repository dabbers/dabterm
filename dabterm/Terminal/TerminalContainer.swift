import SwiftUI
import SwiftTerm
import UIKit

/// SwiftUI wrapper around SwiftTerm's iOS TerminalView wired to a ShellSession.
struct TerminalContainer: UIViewRepresentable {
    let session: ShellSession
    let fontSize: Double

    func makeUIView(context: Context) -> DabTerminalView {
        let tv = DabTerminalView(frame: .zero, font: UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        tv.bind(session)
        return tv
    }
    func updateUIView(_ tv: DabTerminalView, context: Context) {
        if tv.font.pointSize != fontSize { tv.font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }
}

final class DabTerminalView: TerminalView, TerminalViewDelegate, OutputSink {
    private weak var session: ShellSession?
    private var started = false
    private var pending: [UInt8] = []

    func bind(_ s: ShellSession) {
        session = s
        s.terminal = self
        s.focusTerminal = { [weak self] in _ = self?.becomeFirstResponder() }
        terminalDelegate = self
        nativeBackgroundColor = .black
        nativeForegroundColor = UIColor(white: 0.9, alpha: 1)
        allowMouseReporting = false
        optionAsMetaKey = true
        installColors(Self.palette)
        inputAccessoryView = KeyBar(target: self)
        backgroundColor = .black
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !started, bounds.width > 10 {
            started = true
            session?.start()
        }
    }

    // MARK: OutputSink
    func write(_ text: String) {
        let bytes = Array(text.utf8)
        if Thread.isMainThread { feed(byteArray: bytes[...]) } else { DispatchQueue.main.async { self.feed(byteArray: bytes[...]) } }
    }

    /// Called by the key bar to inject a key sequence.
    func inject(_ bytes: [UInt8]) { session?.feed(bytes: bytes) }

    /// Soft-keyboard text while Ctrl/Alt is sticky becomes a control sequence.
    override func insertText(_ text: String) {
        if let bar = inputAccessoryView as? KeyBar, let bytes = bar.transform(text) { session?.feed(bytes: bytes); return }
        super.insertText(text)
    }

    // MARK: TerminalViewDelegate
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let b = Array(data)
        DispatchQueue.main.async { self.session?.feed(bytes: b) }
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { session?.resize(cols: newCols, rows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { session?.title = title }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) { if let u = URL(string: link) { UIApplication.shared.open(u) } }
    func bell(source: TerminalView) { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    func clipboardCopy(source: TerminalView, content: Data) { UIPasteboard.general.string = String(decoding: content, as: UTF8.self) }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    static let palette: [SwiftTerm.Color] = [
        // One Dark-ish ANSI palette (normal 0-7, bright 8-15)
        c(0x28, 0x2c, 0x34), c(0xe0, 0x6c, 0x75), c(0x98, 0xc3, 0x79), c(0xe5, 0xc0, 0x7b), c(0x61, 0xaf, 0xef), c(0xc6, 0x78, 0xdd), c(0x56, 0xb6, 0xc2), c(0xab, 0xb2, 0xbf),
        c(0x5c, 0x63, 0x70), c(0xe0, 0x6c, 0x75), c(0x98, 0xc3, 0x79), c(0xe5, 0xc0, 0x7b), c(0x61, 0xaf, 0xef), c(0xc6, 0x78, 0xdd), c(0x56, 0xb6, 0xc2), c(0xff, 0xff, 0xff),
    ]
    private static func c(_ r: UInt16, _ g: UInt16, _ b: UInt16) -> SwiftTerm.Color { SwiftTerm.Color(red: r * 257, green: g * 257, blue: b * 257) }
}
