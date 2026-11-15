import SwiftUI
import WebKit
import UIKit

/// Controller object that owns the CodeMirror web view and the open-file state.
@MainActor
final class EditorController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    @Published var openFile: URL? = nil
    @Published var dirty = false
    @Published var cursor = (line: 1, col: 1)
    @Published var status = ""
    @Published var tabs: [URL] = []
    private(set) var ready = false
    private var pendingOpen: URL? = nil
    private var pendingLine: Int? = nil
    var onSaved: ((URL) -> Void)?

    lazy var webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(self, name: "editor")
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.navigationDelegate = self
        wv.isOpaque = false; wv.backgroundColor = UIColor(red: 0.157, green: 0.173, blue: 0.204, alpha: 1)
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "editor") {
            wv.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            wv.loadHTMLString("<body style='background:#282c34;color:#ccc;font-family:-apple-system;padding:20px'>Editor bundle missing: run <code>npm run build</code> in dabterm/Editor/web</body>", baseURL: nil)
        }
        return wv
    }()

    func userContentController(_ c: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            ready = true
            applySettings()
            if let p = pendingOpen { pendingOpen = nil; open(p, line: pendingLine); pendingLine = nil }
        case "dirty": dirty = true
        case "clipboard": if let t = body["text"] as? String { UIPasteboard.general.string = t; status = "Copied \(t.count) chars" }
        case "cursor": if let l = body["line"] as? Int, let c = body["col"] as? Int { cursor = (l, c) }
        case "save":
            guard let path = body["path"] as? String, let content = body["content"] as? String else { return }
            let url = URL(fileURLWithPath: path)
            do { try content.write(to: url, atomically: true, encoding: .utf8); dirty = false; status = "Saved \(url.lastPathComponent)"; onSaved?(url) }
            catch { status = "Save failed: \(error.localizedDescription)" }
        default: break
        }
    }

    func open(_ url: URL, line: Int? = nil) {
        guard ready else { pendingOpen = url; pendingLine = line; return }
        if dirty, let cur = openFile, cur != url { save() }
        guard let data = FileManager.default.contents(atPath: url.path) else { status = "Cannot read \(url.lastPathComponent)"; return }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { status = "Binary file"; return }
        openFile = url; dirty = false
        if !tabs.contains(url) { tabs.append(url) }
        call("dabterm.open(\(js(url.path)), \(js(text)))")
        if let line { call("dabterm.goto(\(line))") }
        status = Workspace.display(url)
    }
    func close(_ url: URL) {
        if openFile == url, dirty { save() }
        tabs.removeAll { $0 == url }
        if openFile == url { if let next = tabs.last { open(next) } else { openFile = nil; call("dabterm.open('', '')") } }
    }
    func save() { guard openFile != nil else { return }; call("dabterm.save()") }
    func applySettings() {
        let size = UserDefaults.standard.double(forKey: "editorFontSize")
        call("dabterm.setFontSize(\(size > 0 ? size : 14)); dabterm.setWrap(\(UserDefaults.standard.object(forKey: "editorWrap") as? Bool ?? true))")
    }
    func key(_ name: String) { call("dabterm.key(\(js(name)))") }
    func insert(_ text: String) { call("dabterm.insert(\(js(text)))") }
    func command(_ name: String) { call("dabterm.\(name)()") }
    func focus() { webView.becomeFirstResponder(); call("dabterm.focus()") }

    private func call(_ script: String) { webView.evaluateJavaScript(script) { _, _ in } }
    private func js(_ s: String) -> String {
        let d = try! JSONSerialization.data(withJSONObject: [s])
        let arr = String(decoding: d, as: UTF8.self)
        return String(arr.dropFirst().dropLast())
    }
}

struct EditorWebView: UIViewRepresentable {
    @ObservedObject var controller: EditorController
    func makeUIView(context: Context) -> WKWebView {
        let wv = controller.webView
        EditorKeyBarInstaller.install(on: wv, controller: controller)
        return wv
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// WKWebView does not expose inputAccessoryView directly; swap the content view's class at runtime
/// (the standard trick) so our KeyBar appears above the keyboard while editing.
enum EditorKeyBarInstaller {
    static var bars: [ObjectIdentifier: KeyBar] = [:]
    static func install(on wv: WKWebView, controller: EditorController) {
        guard let target = wv.scrollView.subviews.first(where: { String(describing: type(of: $0)).hasPrefix("WKContent") }) else { return }
        let bar = KeyBar(frame: CGRect(x: 0, y: 0, width: 320, height: UIDevice.current.userInterfaceIdiom == .phone ? 40 : 46), handler: { key in
            Task { @MainActor in
                switch key {
                case .copy: controller.command("copy")
                case .cut: controller.command("cut")
                case .selectAll: controller.command("selectAll")
                case .select: break
                case .esc: controller.key("esc")
                case .tab: controller.key("tab")
                case .up: controller.key("up"); case .down: controller.key("down"); case .left: controller.key("left"); case .right: controller.key("right")
                case .home: controller.key("home"); case .end: controller.key("end")
                case .text(let s): controller.insert(s)
                case .paste: if let s = UIPasteboard.general.string { controller.insert(s) }
                case .hideKeyboard: wv.endEditing(true)
                case .ctrl, .alt: break
                }
            }
        }, showsCut: true)
        bar.onSelectModeChanged = { (on: Bool) in Task { @MainActor in controller.webView.evaluateJavaScript("dabterm.setSelectMode(\(on))") { _, _ in } } }
        bars[ObjectIdentifier(wv)] = bar
        let newClassName = "DabWKContentWithBar_\(String(describing: type(of: target)))"
        if let cls = NSClassFromString(newClassName) { object_setClass(target, cls); return }
        guard let newClass = objc_allocateClassPair(type(of: target), newClassName, 0) else { return }
        let block: @convention(block) (UIView) -> UIView? = { view in
            var v: UIView? = view
            while let x = v, !(x is WKWebView) { v = x.superview }
            return (v as? WKWebView).flatMap { bars[ObjectIdentifier($0)] }
        }
        let imp = imp_implementationWithBlock(block)
        class_addMethod(newClass, NSSelectorFromString("inputAccessoryView"), imp, "@@:")
        objc_registerClassPair(newClass)
        object_setClass(target, newClass)
    }
}
