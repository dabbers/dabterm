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
    /// Height currently occupied by the floating bar (0 when docked normally); the root view pads by this.
    @Published private(set) var floatingHeight: CGFloat = 0

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
        self.bar = bar
        self.owner = owner
        layout()
    }

    private func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        log("active=\(on)")
        if !on { hide() }
        // Make UIKit re-ask for the accessory view so it docks or undocks the bar.
        (owner ?? UIApplication.firstResponder)?.reloadInputViews()
    }

    private func keyboardChanged(_ frame: CGRect) {
        keyboardFrame = frame
        if hadHinge { log("keyboard frame=\(frame.integral) active=\(active)") }
        layout()
    }

    private func layout() {
        guard active, let bar, let window = (owner as? UIView)?.window ?? UIApplication.keyWindow else { hide(); return }
        guard !keyboardFrame.isNull else { hide(); return }
        let kb = window.convert(keyboardFrame, from: nil)
        guard kb.minY < window.bounds.maxY else { hide(); return }
        let h = bar.intrinsicContentSize.height
        if bar.superview !== window {
            bar.removeFromSuperview()
            bar.translatesAutoresizingMaskIntoConstraints = true
            window.addSubview(bar)
        }
        bar.frame = CGRect(x: 0, y: kb.minY - h, width: window.bounds.width, height: h)
        window.bringSubviewToFront(bar)
        if floatingHeight != h { floatingHeight = h }
        log("float bar at y=\(Int(bar.frame.minY)) kbTop=\(Int(kb.minY)) windowH=\(Int(window.bounds.height))")
    }

    private func hide() {
        if let bar, bar.superview is UIWindow { bar.removeFromSuperview() }
        if floatingHeight != 0 { floatingHeight = 0 }
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
