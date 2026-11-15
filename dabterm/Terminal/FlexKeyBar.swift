import UIKit
import Combine

/// Foldable support. When the phone is held half-open (laptop style) iOS docks the keyboard on the
/// lower panel and parks every `inputAccessoryView` above the hinge, on the upper panel. That puts
/// esc/ctrl/arrows a thumb-stretch away from the keys. While the hinge is partially open we return
/// nil for the accessory view and float the same KeyBar in the window directly above the keyboard.
@MainActor
final class FlexKeyBar: ObservableObject {
    static let shared = FlexKeyBar()

    /// True while the hinge is partially open and the bar should float.
    @Published private(set) var active = false
    /// Distance from the window's bottom edge to the top of the floating bar (0 when docked normally).
    /// The root view ignores the keyboard safe area and pads by this instead, so content reaches the bar.
    @Published private(set) var floatingInset: CGFloat = 0

    private var hingeStates: [ObjectIdentifier: Bool] = [:]
    private var keyboardFrame: CGRect = .null   // screen coordinates
    private weak var bar: KeyBar?
    private weak var owner: UIResponder?
    private var hadHinge = false
    private let logURL = Workspace.root.appendingPathComponent("hinge.log")

    private init() {
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] n in
            guard let frame = (n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
            MainActor.assumeIsolated { self?.keyboardChanged(frame) }
        }
        nc.addObserver(forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardChanged(.null) }
        }
    }

    /// Start observing the hinge through `view`'s hierarchy (no-op before iOS 27.1 or on flat devices).
    func observe(_ view: UIView) {
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
                    self.setActive(self.hingeStates.values.contains(true))
                }
            }
            view.addInteraction(interaction)
        }
    }

    /// Called from an accessory-view getter while active: float `bar` for `owner` and return nil to UIKit.
    func show(_ bar: KeyBar, owner: UIResponder) {
        if self.bar !== bar { hide() }
        self.bar = bar
        self.owner = owner
        // UIKit is mid-way through reloading input views; touch the hierarchy on the next turn.
        DispatchQueue.main.async { self.layout() }
    }

    /// Container for the floating bar content; a plain view, so UIKit's input-view controllers are never involved.
    private let container: UIView = {
        let v = UIView(); v.backgroundColor = UIColor(white: 0.08, alpha: 1); return v
    }()

    private func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        log("active=\(on)")
        if !on { hide() }
        // Make UIKit re-ask for the accessory view so it docks or undocks the bar.
        DispatchQueue.main.async { [self] in (owner ?? UIApplication.firstResponder)?.reloadInputViews() }
    }

    private func keyboardChanged(_ frame: CGRect) {
        keyboardFrame = frame
        if hadHinge { log("keyboard frame=\(frame.integral) active=\(active)") }
        // Remember the keyboard's natural height (minus the docked bar) while the hinge is not half-open.
        if !active, !frame.isNull, frame.height > 80, let w = UIApplication.keyWindow, frame.height < w.bounds.height * 0.42 {
            let barH: CGFloat = UIDevice.current.userInterfaceIdiom == .phone ? 40 : 46
            naturalKeyboardHeight[Int(w.bounds.width)] = frame.height - barH
        }
        layout()
        if hadHinge, active, !frame.isNull, frame.height > 50, let w = (owner as? UIView)?.window ?? UIApplication.keyWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [self] in dumpKeyboardWindows(into: w); layout() }
        }
    }

    private func layout() {
        guard active, let bar, let window = (owner as? UIView)?.window ?? UIApplication.keyWindow else { hide(); return }
        guard !keyboardFrame.isNull else { hide(); return }
        var kb = window.convert(keyboardFrame, from: nil)
        guard kb.minY < window.bounds.maxY else { hide(); return }
        // On a half-open fold the reported keyboard frame starts at the hinge and includes an empty band
        // above the keys. Use the real key-plane view when we can find it, so the bar hugs the keys.
        if let keys = Self.visibleKeyboardFrame(in: window), keys.minY > kb.minY + 8, keys.minY < kb.maxY {
            kb = keys
        } else if let natural = naturalKeyboardHeight[Int(window.bounds.width)], kb.height > natural + 30 {
            kb.origin.y = kb.maxY - natural
        } else if kb.height > window.bounds.height * 0.42 {
            // Padded frame and no flat-mode measurement yet: assume a typical keyboard height.
            kb.origin.y = kb.maxY - (window.bounds.height * 0.345).rounded()
        }
        let h = bar.intrinsicContentSize.height
        if container.superview !== window { container.removeFromSuperview(); window.addSubview(container) }
        container.frame = CGRect(x: 0, y: kb.minY - h, width: window.bounds.width, height: h)
        if bar.content.superview !== container {
            bar.content.removeFromSuperview()
            container.addSubview(bar.content)
        }
        bar.content.frame = container.bounds
        window.bringSubviewToFront(container)
        let inset = window.bounds.maxY - container.frame.minY
        if floatingInset != inset { floatingInset = inset }
        let msg = "float bar at y=\(Int(container.frame.minY)) kbTop=\(Int(kb.minY)) windowH=\(Int(window.bounds.height))"
        if msg != lastLayoutMsg { lastLayoutMsg = msg; log(msg) }
    }

    private func hide() {
        if let bar, bar.content.superview === container {
            bar.content.removeFromSuperview()
            bar.content.frame = bar.bounds
            bar.addSubview(bar.content)
        }
        container.removeFromSuperview()
        if floatingInset != 0 { floatingInset = 0 }
    }

    // MARK: Keyboard window inspection (read-only; frames of the system keyboard's own views)
    private static func allWindows() -> [UIWindow] {
        var ws = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for w in UIApplication.shared.windows where !ws.contains(w) { ws.append(w) }
        return ws
    }
    /// Frame (in `window` coordinates) of the keyboard's key plane, if the keyboard window is visible in-process.
    static func visibleKeyboardFrame(in window: UIWindow) -> CGRect? {
        var best: CGRect?
        for w in allWindows() where "\(type(of: w))".contains("Keyboard") || "\(type(of: w))".contains("TextEffects") {
            func walk(_ v: UIView, _ depth: Int) {
                let name = "\(type(of: v))"
                if name.contains("RemoteKeyboardPlaceholder") || name.contains("UIKeyboardImpl") || name.contains("KBKeyplaneView") {
                    let f = window.convert(v.bounds, from: v)
                    if f.height > 80, best == nil || f.minY > best!.minY { best = f }
                }
                if depth < 10 { for sub in v.subviews where !sub.isHidden { walk(sub, depth + 1) } }
            }
            walk(w, 0)
        }
        return best
    }
    private var lastLayoutMsg = ""
    /// Keyboard height without the bar, keyed by window width (orientation), measured while flat.
    private var naturalKeyboardHeight: [Int: CGFloat] = [:]
    private var dumpedFrame: CGRect = .null
    /// One-shot hierarchy dump per keyboard frame, for diagnosing fold layouts from ~/hinge.log.
    private func dumpKeyboardWindows(into window: UIWindow) {
        guard dumpedFrame != keyboardFrame else { return }
        dumpedFrame = keyboardFrame
        for w in Self.allWindows() where w !== window {
            log("window \(type(of: w)) frame=\(w.frame.integral) hidden=\(w.isHidden) level=\(w.windowLevel.rawValue)")
            func walk(_ v: UIView, _ depth: Int) {
                let f = window.convert(v.bounds, from: v).integral
                if f.height >= 30 { log("  \(String(repeating: " ", count: depth))\(type(of: v)) \(f)") }
                if depth < 7 { for sub in v.subviews where !sub.isHidden { walk(sub, depth + 1) } }
            }
            walk(w, 0)
        }
    }

    private func log(_ s: String) {
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
