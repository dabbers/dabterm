import UIKit

/// Keys the iOS keyboard lacks: Esc, Tab, Ctrl (sticky), Alt (sticky), arrows, and common
/// shell symbols. Works for the terminal (byte injection) and the editor (JS bridge).
final class KeyBar: UIInputView {
    enum Key { case esc, tab, ctrl, alt, up, down, left, right, home, end, text(String), paste, hideKeyboard, select, copy, cut, selectAll }
    private var ctrlOn = false, altOn = false
    private var ctrlButton: UIButton?, altButton: UIButton?, selectButton: UIButton?
    /// Selection mode: drag selects text instead of scrolling; arrows extend the selection.
    private(set) var selectOn = false
    var onSelectModeChanged: ((Bool) -> Void)?
    /// Whether to show a cut key (editor only).
    var showsCut = false
    private let handler: (Key) -> Void
    weak var terminal: DabTerminalView?

    convenience init(target: DabTerminalView) {
        self.init(frame: CGRect(x: 0, y: 0, width: 320, height: UIDevice.current.userInterfaceIdiom == .phone ? 40 : 46), showsCut: false) { _ in }
        terminal = target
        handlerBox.fn = { [weak self] k in self?.sendToTerminal(k) }
        onSelectModeChanged = { [weak target] on in target?.setSelectMode(on) }
    }
    private final class Box { var fn: (Key) -> Void = { _ in } }
    private let handlerBox = Box()

    init(frame: CGRect, handler: @escaping (Key) -> Void, showsCut: Bool = false) {
        self.handler = handler
        self.showsCut = showsCut
        super.init(frame: frame, inputViewStyle: .keyboard)
        handlerBox.fn = handler
        autoresizingMask = .flexibleHeight
        build()
    }
    required init?(coder: NSCoder) { fatalError() }
    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: frame.height) }

    /// Everything visible lives in `content`, a plain view that FlexKeyBar can lift out of this
    /// input view and float elsewhere. The UIInputView itself must stay where UIKit put it.
    let content = UIView()

    private func build() {
        content.frame = bounds
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        content.backgroundColor = .clear
        addSubview(content)
        let scroll = UIScrollView(); scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        let stack = UIStackView(); stack.axis = .horizontal; stack.spacing = 6; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor), scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -8),
        ])
        var items: [(String, Key, Bool)] = [
            ("sel", .select, true), ("copy", .copy, false)] + (showsCut ? [("cut", .cut, false)] : []) + [("paste", .paste, false),
            ("esc", .esc, false), ("tab", .tab, false), ("ctrl", .ctrl, true), ("alt", .alt, true),
            ("←", .left, false), ("↓", .down, false), ("↑", .up, false), ("→", .right, false),
            ("-", .text("-"), false), ("/", .text("/"), false), ("|", .text("|"), false), ("~", .text("~"), false),
            ("`", .text("`"), false), ("\\", .text("\\"), false), ("'", .text("'"), false), ("\"", .text("\""), false),
            ("{", .text("{"), false), ("}", .text("}"), false), ("[", .text("["), false), ("]", .text("]"), false),
            ("<", .text("<"), false), (">", .text(">"), false), ("$", .text("$"), false), ("&", .text("&"), false),
            ("home", .home, false), ("end", .end, false), ("all", .selectAll, false), ("⌨︎", .hideKeyboard, false),
        ]
        items = items.filter { _ in true }
        for (title, key, sticky) in items {
            let b = UIButton(type: .system)
            var cfg = UIButton.Configuration.gray()
            cfg.title = title
            cfg.baseForegroundColor = .white
            cfg.baseBackgroundColor = UIColor(white: 0.22, alpha: 1)
            cfg.cornerStyle = .medium
            cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
            cfg.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { var a = $0; a.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .medium); return a }
            b.configuration = cfg
            b.addAction(UIAction { [weak self] _ in self?.tapped(key, button: b) }, for: .touchUpInside)
            if sticky { switch key { case .ctrl: ctrlButton = b; case .alt: altButton = b; case .select: selectButton = b; default: break } }
            // arrows repeat on long press
            if case .left = key { addRepeat(b, key) }; if case .right = key { addRepeat(b, key) }
            if case .up = key { addRepeat(b, key) }; if case .down = key { addRepeat(b, key) }
            stack.addArrangedSubview(b)
        }
    }
    private var repeatTimer: Timer?
    private func addRepeat(_ b: UIButton, _ key: Key) {
        let lp = UILongPressGestureRecognizer(target: self, action: #selector(longPress(_:)))
        lp.minimumPressDuration = 0.35
        b.addGestureRecognizer(lp)
        b.accessibilityHint = { switch key { case .left: return "left"; case .right: return "right"; case .up: return "up"; default: return "down" } }()
    }
    @objc private func longPress(_ g: UILongPressGestureRecognizer) {
        guard let b = g.view as? UIButton else { return }
        let key: Key = { switch b.accessibilityHint { case "left": return .left; case "right": return .right; case "up": return .up; default: return .down } }()
        switch g.state {
        case .began:
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in self?.handlerBox.fn(key) }
        case .ended, .cancelled, .failed: repeatTimer?.invalidate(); repeatTimer = nil
        default: break
        }
    }

    private func tapped(_ key: Key, button: UIButton) {
        UIDevice.current.playInputClick()
        switch key {
        case .ctrl: ctrlOn.toggle(); style(button, on: ctrlOn); return
        case .alt: altOn.toggle(); style(button, on: altOn); return
        case .select: selectOn.toggle(); style(button, on: selectOn); onSelectModeChanged?(selectOn); return
        default: break
        }
        handlerBox.fn(key)
    }
    private func style(_ b: UIButton, on: Bool) {
        b.configuration?.baseBackgroundColor = on ? .systemCyan : UIColor(white: 0.22, alpha: 1)
        b.configuration?.baseForegroundColor = on ? .black : .white
    }
    func setSelectMode(_ on: Bool) { selectOn = on; if let b = selectButton { style(b, on: on) } }
    private func consumeModifiers() -> (ctrl: Bool, alt: Bool) {
        let r = (ctrlOn, altOn)
        if ctrlOn, let b = ctrlButton { ctrlOn = false; style(b, on: false) }
        if altOn, let b = altButton { altOn = false; style(b, on: false) }
        return r
    }

    /// Terminal mode: translate to bytes.
    private func sendToTerminal(_ key: Key) {
        guard let t = terminal else { return }
        let mods = consumeModifiers()
        switch key {
        case .esc: t.inject([0x1b])
        case .tab: t.inject([0x09])
        case .up: t.inject(Array("\u{1b}[A".utf8)); case .down: t.inject(Array("\u{1b}[B".utf8))
        case .right: t.inject(Array("\u{1b}[C".utf8)); case .left: t.inject(Array("\u{1b}[D".utf8))
        case .home: t.inject(Array("\u{1b}[H".utf8)); case .end: t.inject(Array("\u{1b}[F".utf8))
        case .paste: if let s = UIPasteboard.general.string { t.inject(Array(s.utf8)) }
        case .hideKeyboard: t.resignFirstResponder()
        case .copy: t.copySelectionOrLine()
        case .cut: t.copySelectionOrLine()
        case .selectAll: t.selectAll(nil); setSelectMode(true); onSelectModeChanged?(true)
        case .select: break
        case .text(let s):
            var bytes = Array(s.utf8)
            if mods.ctrl, let c = s.uppercased().utf8.first, c >= 0x40, c <= 0x5f { bytes = [c - 0x40] }
            if mods.alt { bytes = [0x1b] + bytes }
            t.inject(bytes)
        case .ctrl, .alt: break
        }
    }

    /// Ctrl+letter typed on the soft keyboard while ctrl is sticky: terminal view calls this.
    func transform(_ text: String) -> [UInt8]? {
        guard ctrlOn || altOn else { return nil }
        let mods = consumeModifiers()
        var bytes = Array(text.utf8)
        if mods.ctrl, text.count == 1, let c = text.uppercased().utf8.first, c >= 0x40, c <= 0x5f { bytes = [c - 0x40] }
        if mods.alt { bytes = [0x1b] + bytes }
        return bytes
    }
    var isCtrlOn: Bool { ctrlOn }
}
