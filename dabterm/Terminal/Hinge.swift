import UIKit

/// Watches the hinge of a foldable (iOS 27.1+) and logs keyboard/layout events to ~/hinge.log on
/// such devices, so posture problems can be diagnosed from the phone. Half-open in portrait, iOS
/// shrinks the app window to the upper half and puts its keyboard in the lower half; the app only
/// needs to know that posture to size the key bar (see KeyboardInset).
@MainActor
final class HingeMonitor {
    static let shared = HingeMonitor()
    private(set) var partiallyOpen = false
    /// Called after every hinge update (status or angle).
    var onChange: (() -> Void)?
    private var states: [ObjectIdentifier: Bool] = [:]
    private var hadHinge = false
    private let logURL = Workspace.root.appendingPathComponent("hinge.log")

    private init() {
        // Debug aid: DABTERM_POSTURE=partiallyOpen pretends the hinge is half-open on a plain simulator.
        if ProcessInfo.processInfo.environment["DABTERM_POSTURE"] == "partiallyOpen" {
            states[ObjectIdentifier(self)] = true
            partiallyOpen = true
            hadHinge = true
        }
    }

    /// Follow the hinge through a view that stays in the window.
    func watch(_ view: UIView) {
        if #available(iOS 27.1, *) {
            let id = ObjectIdentifier(view)
            let interaction = UIHingeInteraction { [weak self] _, update in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let hinge = update.hinge {
                        self.hadHinge = true
                        self.states[id] = hinge.status == .partiallyOpen
                        self.log("hinge status=\(hinge.status.rawValue) angle=\(String(format: "%.2f", hinge.angle))")
                    } else {
                        self.states[id] = nil
                    }
                    self.partiallyOpen = self.states.values.contains(true)
                    self.onChange?()
                }
            }
            view.addInteraction(interaction)
        }
    }

    func log(_ s: String) {
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
    @objc func _dabCaptureFirstResponder() { UIResponder._captured = self }
}
