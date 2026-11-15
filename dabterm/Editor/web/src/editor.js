// dabterm editor: CodeMirror 6 bundle. Built with `npm run build` into Resources/editor/editor.js.
// The native side talks to window.dabterm.* and receives messages via webkit.messageHandlers.editor.
import { EditorState, Compartment } from "@codemirror/state";
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
  key(name) {
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
