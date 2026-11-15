// dabterm editor: CodeMirror 6 bundle. Built with `npm run build` into Resources/editor/editor.js.
// The native side talks to window.dabterm.* and receives messages via webkit.messageHandlers.editor.
import { EditorState, Compartment, EditorSelection } from "@codemirror/state";
import { EditorView, keymap, lineNumbers, highlightActiveLine, highlightActiveLineGutter,
         drawSelection, dropCursor, rectangularSelection, crosshairCursor, highlightSpecialChars } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab, undo, redo, selectAll } from "@codemirror/commands";
import { searchKeymap, highlightSelectionMatches, openSearchPanel, search } from "@codemirror/search";
import { autocompletion, closeBrackets, closeBracketsKeymap, completionKeymap } from "@codemirror/autocomplete";
import { bracketMatching, foldGutter, foldKeymap, indentOnInput, syntaxHighlighting, defaultHighlightStyle, StreamLanguage, indentUnit } from "@codemirror/language";
import { oneDark } from "@codemirror/theme-one-dark";
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { cpp } from "@codemirror/lang-cpp";
import { rust } from "@codemirror/lang-rust";
import { go } from "@codemirror/lang-go";
import { yaml } from "@codemirror/lang-yaml";
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { nginx } from "@codemirror/legacy-modes/mode/nginx";
import { properties } from "@codemirror/legacy-modes/mode/properties";

const language = new Compartment();
const theme = new Compartment();
const fontSize = new Compartment();
const wrap = new Compartment();

let settings = { fontSize: 14, wrap: true, dark: true };
let currentPath = null;
let dirty = false;

function langFor(path) {
  const name = (path || "").split("/").pop().toLowerCase();
  const ext = name.includes(".") ? name.split(".").pop() : name;
  switch (ext) {
    case "js": case "mjs": case "cjs": return javascript();
    case "jsx": return javascript({ jsx: true });
    case "ts": return javascript({ typescript: true });
    case "tsx": return javascript({ typescript: true, jsx: true });
    case "py": return python();
    case "json": case "jsonc": return json();
    case "md": case "markdown": return markdown();
    case "html": case "htm": case "xml": case "svg": case "plist": return html();
    case "css": case "scss": case "less": return css();
    case "c": case "h": case "cc": case "cpp": case "hpp": case "m": case "mm": return cpp();
    case "rs": return rust();
    case "go": return go();
    case "yml": case "yaml": return yaml();
    case "sh": case "bash": case "zsh": case "zshrc": case "bashrc": case "profile": return StreamLanguage.define(shell);
    case "swift": return StreamLanguage.define(swift);
    case "toml": return StreamLanguage.define(toml);
    case "rb": return StreamLanguage.define(ruby);
    case "dockerfile": return StreamLanguage.define(dockerFile);
    case "conf": case "nginx": return StreamLanguage.define(nginx);
    case "ini": case "env": case "properties": case "config": return StreamLanguage.define(properties);
    default: return [];
  }
}

function post(msg) {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.editor;
  if (h) h.postMessage(msg);
}

const baseTheme = EditorView.theme({
  "&": { height: "100%" },
  ".cm-scroller": { fontFamily: "Menlo, 'SF Mono', ui-monospace, monospace", overscrollBehavior: "contain" },
  ".cm-content": { padding: "8px 0 50vh 0" },
  ".cm-gutters": { minWidth: "3.2em" }
});

const fontTheme = px => EditorView.theme({ "&": { fontSize: px + "px" } });

function save() {
  post({ type: "save", path: currentPath, content: view.state.doc.toString() });
  dirty = false;
}

function makeState(doc, path) {
  return EditorState.create({
    doc,
    extensions: [
      lineNumbers(), highlightActiveLineGutter(), highlightSpecialChars(), history(), foldGutter(),
      drawSelection(), dropCursor(), EditorState.allowMultipleSelections.of(true), indentOnInput(),
      syntaxHighlighting(defaultHighlightStyle, { fallback: true }), bracketMatching(), closeBrackets(),
      autocompletion(), rectangularSelection(), crosshairCursor(), highlightActiveLine(), highlightSelectionMatches(),
      search({ top: true }),
      keymap.of([...closeBracketsKeymap, ...defaultKeymap, ...searchKeymap, ...historyKeymap, ...foldKeymap, ...completionKeymap, indentWithTab,
        { key: "Mod-s", run: () => { save(); return true; } }]),
      indentUnit.of("    "),
      language.of(langFor(path)),
      theme.of(settings.dark ? oneDark : []),
      fontSize.of(fontTheme(settings.fontSize)),
      wrap.of(settings.wrap ? EditorView.lineWrapping : []),
      baseTheme,
      EditorView.updateListener.of(u => {
        if (u.docChanged && !dirty) { dirty = true; post({ type: "dirty", path: currentPath }); }
        if (u.selectionSet || u.docChanged) {
          const head = u.state.selection.main.head;
          const line = u.state.doc.lineAt(head);
          post({ type: "cursor", line: line.number, col: head - line.from + 1 });
        }
      })
    ]
  });
}

const view = new EditorView({ state: makeState("", null), parent: document.getElementById("editor") });

const keyMap = { left: "ArrowLeft", right: "ArrowRight", up: "ArrowUp", down: "ArrowDown", home: "Home", end: "End", esc: "Escape" };

// ---- Select mode: touch-drag selects text instead of scrolling; arrows extend the selection.
let selectMode = false;
let dragAnchor = null;
const scroller = view.scrollDOM;
function posAt(t) { const p = view.posAtCoords({ x: t.clientX, y: t.clientY }); return p == null ? null : p; }
scroller.addEventListener("touchstart", e => {
  if (!selectMode || e.touches.length !== 1) return;
  const pos = posAt(e.touches[0]);
  if (pos == null) return;
  dragAnchor = pos;
  view.dispatch({ selection: EditorSelection.single(pos) });
  e.preventDefault();
}, { passive: false });
scroller.addEventListener("touchmove", e => {
  if (!selectMode || dragAnchor == null) return;
  const pos = posAt(e.touches[0]);
  if (pos != null) view.dispatch({ selection: EditorSelection.single(dragAnchor, pos), scrollIntoView: true });
  e.preventDefault();
}, { passive: false });
scroller.addEventListener("touchend", () => { dragAnchor = null; });
function extend(dir) {
  const sel = view.state.selection.main;
  const line = view.state.doc.lineAt(sel.head);
  let head = sel.head;
  if (dir === "left") head = Math.max(0, head - 1);
  else if (dir === "right") head = Math.min(view.state.doc.length, head + 1);
  else if (dir === "home") head = line.from;
  else if (dir === "end") head = line.to;
  else if (dir === "up" || dir === "down") {
    const n = line.number + (dir === "up" ? -1 : 1);
    if (n < 1 || n > view.state.doc.lines) return;
    const target = view.state.doc.line(n);
    head = Math.min(target.to, target.from + (head - line.from));
  }
  view.dispatch({ selection: EditorSelection.single(sel.anchor, head), scrollIntoView: true });
}

window.dabterm = {
  open(path, content) {
    currentPath = path; dirty = false;
    view.setState(makeState(content, path));
    post({ type: "opened", path });
  },
  save,
  content() { return view.state.doc.toString(); },
  setFontSize(px) { settings.fontSize = px; view.dispatch({ effects: fontSize.reconfigure(fontTheme(px)) }); },
  setWrap(on) { settings.wrap = on; view.dispatch({ effects: wrap.reconfigure(on ? EditorView.lineWrapping : []) }); },
  setDark(on) { settings.dark = on; view.dispatch({ effects: theme.reconfigure(on ? oneDark : []) }); },
  undo() { undo(view); },
  redo() { redo(view); },
  selectAll() { selectAll(view); view.focus(); },
  find() { openSearchPanel(view); },
  insert(text) { view.dispatch(view.state.replaceSelection(text)); view.focus(); },
  setSelectMode(on) { selectMode = on; dragAnchor = null; scroller.style.touchAction = on ? "none" : ""; if (!on) { const h = view.state.selection.main.head; view.dispatch({ selection: EditorSelection.single(h) }); } },
  selectedText() { const s = view.state.selection.main; return view.state.sliceDoc(s.from, s.to); },
  copy() { const t = window.dabterm.selectedText(); if (t) post({ type: "clipboard", text: t }); return t.length; },
  cut() { const s = view.state.selection.main; const t = view.state.sliceDoc(s.from, s.to); if (t) { post({ type: "clipboard", text: t }); view.dispatch({ changes: { from: s.from, to: s.to, insert: "" } }); } return t.length; },
  selectLine() { const s = view.state.selection.main; const a = view.state.doc.lineAt(s.from), b = view.state.doc.lineAt(s.to); const to = b.number < view.state.doc.lines ? view.state.doc.line(b.number + 1).from : b.to; view.dispatch({ selection: EditorSelection.single(a.from, to) }); },
  key(name) {
    if (selectMode && ["left", "right", "up", "down", "home", "end"].includes(name)) { extend(name); return; }
    if (name === "tab") { indentWithTab.run(view); view.focus(); return; }
    view.contentDOM.dispatchEvent(new KeyboardEvent("keydown", { key: keyMap[name] || name, bubbles: true }));
    view.focus();
  },
  focus() { view.focus(); },
  goto(line) {
    const l = Math.max(1, Math.min(line, view.state.doc.lines));
    view.dispatch({ selection: { anchor: view.state.doc.line(l).from }, scrollIntoView: true });
    view.focus();
  }
};

post({ type: "ready" });
