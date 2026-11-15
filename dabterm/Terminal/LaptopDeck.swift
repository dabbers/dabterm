import UIKit
import Combine

/// A key the deck's soft keyboard produces. Hosts (terminal, editor) turn it into bytes or editor calls.
enum SoftKey {
    case text(String)
    case backspace, enter, esc, tab, up, down, left, right
    /// One-shot modifiers armed on the soft keyboard when the key was pressed.
    struct Modifiers: OptionSet { let rawValue: Int; static let ctrl = Modifiers(rawValue: 1); static let alt = Modifiers(rawValue: 2) }
}

/// Foldable support (iPhone Duo). Held half-open like a laptop the inner display is portrait and the
/// hinge crosses it at mid-height. iOS then docks the system keyboard on the lower panel but reports
/// a keyboard frame that starts at the hinge, so accessory views and SwiftUI's keyboard avoidance both
/// land above the hinge, and the keys sit far below them.
///
/// Instead of fighting that, the app owns the lower half: the system keyboard is suppressed with an
/// empty `inputView`, and a `LaptopDeckView` (the key bar strip, then a soft keyboard) is laid over the
/// lower half of the window. The terminal or editor keeps the upper half and stays first responder,
/// so hardware keyboards keep working. Flat devices and landscape postures never see any of this.
@MainActor
final class LaptopDeck: ObservableObject {
    static let shared = LaptopDeck()

    /// True while the deck owns the lower half of the window.
    @Published private(set) var active = false
    /// Height of the deck (0 when inactive); the root view pads its bottom by this.
    @Published private(set) var inset: CGFloat = 0

    /// Shared empty input view: returned as `inputView` while active so the system keyboard stays away.
    static let emptyInputView: UIView = {
        let v = UIView(frame: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }()

    struct Host {
        weak var view: UIView?
        weak var bar: KeyBar?
        let handle: (SoftKey, SoftKey.Modifiers) -> Void
    }
    private var hosts: [ObjectIdentifier: Host] = [:]
    private var hingeStates: [ObjectIdentifier: Bool] = [:]
    private var partiallyOpen: Bool { hingeStates.values.contains(true) }
    private let deckView = LaptopDeckView()
    private weak var currentHost: UIView?
    private var hadHinge = false
    private let logURL = Workspace.root.appendingPathComponent("hinge.log")

    private init() {
        deckView.keyboard.onKey = { [weak self] key, mods in self?.route(key, mods) }
        // Posture is re-checked on anything that can change the window shape or bring a keyboard: rotation,
        // a window becoming key, and keyboard frame changes (the editor's web view focusing, for one).
        for name in [UIDevice.orientationDidChangeNotification, UIWindow.didBecomeKeyNotification,
                     UIResponder.keyboardWillChangeFrameNotification, UIResponder.keyboardWillShowNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        // Debug aid: DABTERM_POSTURE=partiallyOpen forces the deck on a plain simulator.
        if ProcessInfo.processInfo.environment["DABTERM_POSTURE"] == "partiallyOpen" {
            hingeStates[ObjectIdentifier(self)] = true
            hadHinge = true
        }
    }

    /// Register a view that hosts a key bar and can take soft keys. Also watches the hinge through it.
    func register(_ view: UIView, bar: KeyBar, handle: @escaping (SoftKey, SoftKey.Modifiers) -> Void) {
        hosts[ObjectIdentifier(view)] = Host(view: view, bar: bar, handle: handle)
        if currentHost == nil { currentHost = view }
        DispatchQueue.main.async { [weak self] in self?.refresh() }
        if #available(iOS 27.1, *) {
            let id = ObjectIdentifier(view)
            let interaction = UIHingeInteraction { [weak self] _, update in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let hinge = update.hinge {
                        self.hadHinge = true
                        self.hingeStates[id] = hinge.status == .partiallyOpen
                        self.log("hinge status=\(hinge.status.rawValue) angle=\(String(format: "%.2f", hinge.angle))")
                    } else {
                        self.hingeStates[id] = nil
                    }
                    self.refresh()
                }
            }
            view.addInteraction(interaction)
        }
    }

    /// Hosts call this when they become first responder, so the deck shows their key bar and routes to them.
    func activate(host view: UIView) {
        currentHost = view
        if active { layout() }
    }

    /// Re-evaluate posture and window shape; hosts call it from layoutSubviews too (cheap when nothing changed).
    func refresh() {
        guard let window = hostWindow() else { return }
        let portrait = window.bounds.height > window.bounds.width
        let shouldBeActive = partiallyOpen && portrait
        if shouldBeActive != active {
            active = shouldBeActive
            log("deck active=\(active) window=\(window.bounds.size)")
            if !active { hide() }
            // Make UIKit re-ask every hosted first responder for inputView/inputAccessoryView.
            DispatchQueue.main.async { [self] in
                var responders: [UIResponder] = []
                if let fr = UIApplication.firstResponder { responders.append(fr) }
                for h in hosts.values { if let v = h.view, let fr = Self.firstResponder(in: v), !responders.contains(where: { $0 === fr }) { responders.append(fr) } }
                for r in responders { r.reloadInputViews() }
                layout()
            }
        }
        if active { layout() }
    }

    private func hostWindow() -> UIWindow? {
        if let w = currentHost?.window { return w }
        for h in hosts.values { if let w = h.view?.window { return w } }
        return UIApplication.keyWindow
    }

    private func layout() {
        guard active, let window = hostWindow() else { hide(); return }
        let h = floor(window.bounds.height / 2)
        if deckView.superview !== window { deckView.removeFromSuperview(); window.addSubview(deckView) }
        deckView.frame = CGRect(x: 0, y: window.bounds.height - h, width: window.bounds.width, height: h)
        window.bringSubviewToFront(deckView)
        // The strip is the current host's key bar content, lifted out of its (now unused) accessory view.
        if let bar = targetHost()?.bar { deckView.setStrip(bar.content, from: bar) }
        // SwiftUI still adds the bottom safe area under our padding; the deck covers it, so take it off.
        let want = h - window.safeAreaInsets.bottom
        if inset != want { inset = want }
    }

    private func hide() {
        deckView.returnStrip()
        deckView.removeFromSuperview()
        if inset != 0 { inset = 0 }
    }

    /// The host keys should go to: the one holding keyboard focus, else the one on screen (the tab
    /// view keeps hidden tabs out of the window), else the one the deck was last activated for.
    private func targetHost() -> Host? {
        // On screen first: the terminal can stay first responder while another tab is showing.
        for h in hosts.values {
            if let v = h.view, let w = v.window, !v.isHidden, v.bounds.width > 10, w.bounds.intersects(v.convert(v.bounds, to: w)) { return h }
        }
        if let fr = UIApplication.firstResponder as? UIView {
            for h in hosts.values { if let v = h.view, fr === v || fr.isDescendant(of: v) { return h } }
        }
        if let v = currentHost, let h = hosts[ObjectIdentifier(v)] { return h }
        return hosts.values.first
    }

    private func route(_ key: SoftKey, _ mods: SoftKey.Modifiers) {
        let h = targetHost()
        log("route \(key) -> \(h?.view.map { "\(type(of: $0))" } ?? "none")")
        h?.handle(key, mods)
    }

    private static func firstResponder(in v: UIView) -> UIResponder? {
        if v.isFirstResponder { return v }
        for sub in v.subviews { if let r = firstResponder(in: sub) { return r } }
        return nil
    }

    private func log(_ s: String) {
        guard hadHinge else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
    }
}

extension UIApplication {
    static var keyWindow: UIWindow? {
        shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }
    static var firstResponder: UIResponder? {
        UIResponder._captured = nil
        shared.sendAction(#selector(UIResponder._dabCaptureFirstResponder), to: nil, from: nil, for: nil)
        return UIResponder._captured
    }
}

extension UIResponder {
    nonisolated(unsafe) static weak var _captured: UIResponder?
    @objc fileprivate func _dabCaptureFirstResponder() { UIResponder._captured = self }
}

/// The flat half: the key bar strip right under the hinge, then the soft keyboard.
final class LaptopDeckView: UIView {
    let keyboard = SoftKeyboardView()
    private let stripHolder = UIView()
    private weak var strip: UIView?
    private weak var stripOwner: KeyBar?
    private let stripHeight: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 40 : 46

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        stripHolder.backgroundColor = UIColor(white: 0.11, alpha: 1)
        addSubview(stripHolder)
        addSubview(keyboard)
    }
    required init?(coder: NSCoder) { fatalError() }

    func setStrip(_ content: UIView, from bar: KeyBar) {
        if strip === content { return }
        returnStrip()
        content.removeFromSuperview()
        stripHolder.addSubview(content)
        strip = content; stripOwner = bar
        setNeedsLayout()
    }
    func returnStrip() {
        if let strip, let bar = stripOwner {
            strip.removeFromSuperview()
            strip.frame = bar.bounds
            bar.addSubview(strip)
        }
        strip = nil; stripOwner = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bottom = bounds.height - safeAreaInsets.bottom
        stripHolder.frame = CGRect(x: 0, y: 0, width: bounds.width, height: stripHeight)
        strip?.frame = stripHolder.bounds
        let remaining = bottom - stripHeight - 6
        // Fill most of the panel so keys are thumb-sized; leave a little dead space at the bottom edge.
        let kbHeight = min(remaining, max(keyboard.preferredHeight, floor(remaining * 0.8)))
        keyboard.frame = CGRect(x: safeAreaInsets.left, y: stripHeight + 6, width: bounds.width - safeAreaInsets.left - safeAreaInsets.right, height: kbHeight)
    }
}

/// A compact soft keyboard made of plain views (no UIInputView, so it can live anywhere). Keys fire
/// on touch-down, several fingers may be down at once, gaps belong to the nearest key, and a pressed
/// key lights up with a small balloon above it. ⇧ ⌃ ⌥ are one-shot, as on the key bar.
/// Esc, tab, arrows and friends live on the key bar strip above, so this is just characters.
final class SoftKeyboardView: UIView {
    var onKey: ((SoftKey, SoftKey.Modifiers) -> Void)?

    private enum Action { case text(String, shifted: String), key(SoftKey), shift, ctrl, alt }
    private struct Key { let label: String; let action: Action; var weight: CGFloat = 1 }
    private struct Row { let keys: [Key]; var height: CGFloat = 1 }
    private static func chars(_ plain: String, _ shifted: String) -> [Key] {
        zip(plain, shifted).map { Key(label: String($0), action: .text(String($0), shifted: String($1))) }
    }
    private static let rows: [Row] = [
        Row(keys: chars("`1234567890-=", "~!@#$%^&*()_+") + [Key(label: "⌫", action: .key(.backspace), weight: 1.6)]),
        Row(keys: chars("qwertyuiop[]\\", "QWERTYUIOP{}|")),
        Row(keys: chars("asdfghjkl;'", "ASDFGHJKL:\"") + [Key(label: "return", action: .key(.enter), weight: 1.8)]),
        Row(keys: [Key(label: "⇧", action: .shift, weight: 1.5)] + chars("zxcvbnm,./", "ZXCVBNM<>?") + [Key(label: "⇧", action: .shift, weight: 1.5)]),
        Row(keys: [Key(label: "ctrl", action: .ctrl, weight: 1.3), Key(label: "alt", action: .alt, weight: 1.3),
                   Key(label: "", action: .text(" ", shifted: " "), weight: 6),
                   Key(label: "←", action: .key(.left)), Key(label: "→", action: .key(.right))], height: 0.95),
    ]

    private struct KeyCap { let key: Key; let view: UIView; let label: UILabel }
    private var caps: [KeyCap] = []
    private var shift = false, ctrl = false, alt = false
    private var held: [UITouch: Int] = [:]
    private var balloons: [UITouch: UIView] = [:]
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        for row in Self.rows {
            for key in row.keys {
                let view = UIView()
                view.layer.cornerRadius = 6
                view.layer.cornerCurve = .continuous
                view.isUserInteractionEnabled = false
                let label = UILabel()
                label.textAlignment = .center
                label.textColor = .white
                label.adjustsFontSizeToFitWidth = true
                label.minimumScaleFactor = 0.6
                view.addSubview(label)
                addSubview(view)
                caps.append(KeyCap(key: key, view: view, label: label))
            }
        }
        refreshLabels()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static let gap: CGFloat = 5
    private static let heightUnits = rows.reduce(0) { $0 + $1.height }
    /// Height at which a character row is a comfortable 44 pt.
    var preferredHeight: CGFloat { 44 * Self.heightUnits + Self.gap * CGFloat(Self.rows.count + 1) }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = Self.gap
        let unitHeight = (bounds.height - gap * CGFloat(Self.rows.count + 1)) / Self.heightUnits
        let font = UIFont.monospacedSystemFont(ofSize: min(20, max(11, floor(unitHeight * 0.5))), weight: .regular)
        var index = 0
        var y = gap
        for row in Self.rows {
            let rowHeight = unitHeight * row.height
            let weights = row.keys.reduce(0) { $0 + $1.weight }
            let unit = (bounds.width - gap * CGFloat(row.keys.count + 1)) / weights
            var x = gap
            for key in row.keys {
                let w = unit * key.weight
                let cap = caps[index]
                cap.view.frame = CGRect(x: x, y: y, width: w, height: rowHeight)
                cap.label.frame = cap.view.bounds
                cap.label.font = font
                x += w + gap
                index += 1
            }
            y += rowHeight + gap
        }
    }

    private func keyIndex(at point: CGPoint) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (i, cap) in caps.enumerated() {
            let f = cap.view.frame
            if f.contains(point) { return i }
            let dx = max(f.minX - point.x, 0, point.x - f.maxX)
            let dy = max(f.minY - point.y, 0, point.y - f.maxY)
            let d = dx * dx + dy * dy
            if best == nil || d < best!.distance { best = (i, d) }
        }
        guard let best, best.distance <= (Self.gap + 2) * (Self.gap + 2) else { return nil }
        return best.index
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let index = keyIndex(at: touch.location(in: self)) else { continue }
            held[touch] = index
            setHighlighted(index, true)
            showBalloon(for: touch, over: index)
            haptic.impactOccurred(intensity: 0.7)
            haptic.prepare()
            press(caps[index].key)
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { release(touches) }
    private func release(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let index = held.removeValue(forKey: touch) else { continue }
            balloons.removeValue(forKey: touch)?.removeFromSuperview()
            if !held.values.contains(index) { setHighlighted(index, false) }
        }
    }

    private func showBalloon(for touch: UITouch, over index: Int) {
        let cap = caps[index]
        let keyFrame = cap.view.frame
        let size = CGSize(width: max(keyFrame.width * 1.35, 44), height: keyFrame.height * 1.4)
        var origin = CGPoint(x: keyFrame.midX - size.width / 2, y: keyFrame.minY - size.height - 2)
        origin.x = min(max(origin.x, 0), bounds.width - size.width)
        let balloon = UIView(frame: CGRect(origin: origin, size: size))
        balloon.backgroundColor = UIColor(white: 0.45, alpha: 1)
        balloon.layer.cornerRadius = 8
        balloon.layer.cornerCurve = .continuous
        balloon.layer.shadowColor = UIColor.black.cgColor
        balloon.layer.shadowOpacity = 0.6
        balloon.layer.shadowRadius = 4
        balloon.layer.shadowOffset = CGSize(width: 0, height: 2)
        balloon.isUserInteractionEnabled = false
        let label = UILabel(frame: balloon.bounds)
        label.text = cap.label.text?.isEmpty == false ? cap.label.text : "space"
        label.textAlignment = .center
        label.textColor = .white
        label.font = .monospacedSystemFont(ofSize: cap.label.font.pointSize * 1.3, weight: .medium)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        balloon.addSubview(label)
        addSubview(balloon)
        balloons[touch] = balloon
    }

    private func setHighlighted(_ index: Int, _ on: Bool) {
        let cap = caps[index]
        cap.view.backgroundColor = on ? UIColor(white: 0.55, alpha: 1) : baseColor(for: cap)
        cap.view.transform = on ? CGAffineTransform(scaleX: 1.06, y: 1.06) : .identity
    }
    private func baseColor(for cap: KeyCap) -> UIColor {
        switch cap.key.action {
        case .text: return UIColor(white: 0.24, alpha: 1)
        case .key: return UIColor(white: 0.16, alpha: 1)
        case .shift: return shift ? .systemCyan : UIColor(white: 0.16, alpha: 1)
        case .ctrl: return ctrl ? .systemCyan : UIColor(white: 0.16, alpha: 1)
        case .alt: return alt ? .systemCyan : UIColor(white: 0.16, alpha: 1)
        }
    }

    private func press(_ key: Key) {
        var mods: SoftKey.Modifiers = []
        if ctrl { mods.insert(.ctrl) }
        if alt { mods.insert(.alt) }
        switch key.action {
        case .shift: shift.toggle(); refreshLabels()
        case .ctrl: ctrl.toggle(); refreshLabels()
        case .alt: alt.toggle(); refreshLabels()
        case .key(let k): onKey?(k, mods); clearModifiers()
        case .text(let plain, let shifted):
            onKey?(.text(shift ? shifted : plain), mods)
            clearModifiers()
        }
    }
    private func clearModifiers() {
        guard shift || ctrl || alt else { return }
        shift = false; ctrl = false; alt = false
        refreshLabels()
    }
    private func refreshLabels() {
        let heldIndices = Set(held.values)
        for (i, cap) in caps.enumerated() {
            if case .text(let plain, let shifted) = cap.key.action { cap.label.text = shift ? shifted : plain }
            else { cap.label.text = cap.key.label }
            cap.label.textColor = { switch cap.key.action { case .shift: return shift ? .black : .white; case .ctrl: return ctrl ? .black : .white; case .alt: return alt ? .black : .white; default: return .white } }()
            if !heldIndices.contains(i) { cap.view.backgroundColor = baseColor(for: cap) }
        }
    }
}
