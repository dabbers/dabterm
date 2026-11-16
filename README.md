# dabterm

A terminal for iPhone and iPad with the tools you actually reach for, a real code editor, SSH, and
GitHub sync. Everything lives in a folder you can see in the Files app.

Think Blink Shell, but with the tools built in, an editor that opens local folders, and a keyboard
bar that makes a touch screen usable.

## What it does

**Files app folder.** The app's home directory shows up as *Files → On My iPhone → dabterm*. Save a
download there from Safari or Firefox, drop in SSH keys, clone a repo into `~/projects` — the shell
and the editor see the same files.

**Shell (`dsh`).** Pipes, `>`/`>>` redirection, `$VAR`, globs, `;`, tab completion, history, Ctrl-A/E/U/K/W/L,
and `.sh` scripts in `~/bin` run by name. Built-ins:

| Group | Commands |
|---|---|
| Files | `ls cd pwd cat mkdir rm mv cp touch find tree du stat file edit open` |
| Text (Go framework adds `awk yq gofmt tar zip unzip gzip`) | `echo printf grep head tail wc sort uniq cut tr sed diff jq base64 xxd tee seq` |
| Network | `ping traceroute dig host curl wget http nc portscan ifconfig whois` |
| Crypto | `openssl shasum md5 uuid ssh-keygen` |
| Remote | `ssh scp ssh-copy-id git gh` |
| Scripting | `python` + `pip` (CPython 3.13), `go` (Yaegi), `js` / `node` (JavaScriptCore), `wasm` (WASI), `sh` |
| Shell | `help clear history env export unset alias which date uname sleep sh chsh xargs time watch less patch sqlite3 fzf` |

`ping` and `traceroute` use ICMP datagram sockets (no root needed on iOS). `dig` is a small DNS
client (A/AAAA/MX/TXT/NS/CNAME/SRV/PTR/SOA/CAA, `@server`, `+short`).

**Python.** Real CPython 3.13 (the official iOS build, via BeeWare's Python-Apple-support), bundled
with the full standard library including `ssl`, `sqlite3`, `hashlib`, `asyncio`, `ctypes`, `decimal`,
`zlib`/`bz2`/`lzma`. `python file.py [args]`, `python -c`, `python -m module`, piped stdin, or a REPL;
`.py` files in `~/bin` run by name; `input()` reads from the terminal. `pip install pkg` fetches pure-Python wheels (and their
dependencies) from PyPI into `~/site-packages`; `pip list|show|uninstall` manage them. Packages
with compiled extensions cannot be installed, which is an iOS limit, not a pip one. The interpreter is embedded (one per process, scripts run one
at a time), which is what Apple allows. The framework is not in git: run `scripts/fetch-python.sh`
before building, or the build still succeeds and `python` explains it is missing. ~22 MB in the app.

**Go.** `go run file.go [args]`, `go file.go`, `go -e 'fmt.Println(1)'`, piped source, or a REPL
(expressions print their value). Runs on [Yaegi](https://github.com/traefik/yaegi), a Go interpreter
written in Go, built into the app as a framework with gomobile: no compiler, no JIT, the standard
library compiled in. `.go` files in `~/bin` run by name; source packages under `~/go/src` are
importable; `os.Exit` ends the program, not the app. Third-party modules and cgo are not available,
and `os.Stdin`/`os.Stdout`/`os.Stderr` are plain readers and writers (use `fmt.Fprint`, `bufio`).
The framework is not in git: run `scripts/build-go.sh` (needs Go 1.21+) before building, or the
build still succeeds and `go` explains it is missing.

**fzf.** `fzf` is an interactive fuzzy finder: lines from stdin, or the files under the current
folder when nothing is piped; type to filter, arrows to move, Enter picks. `ls | fzf`,
`edit $(fzf)`. Ctrl-R at the prompt searches the shell history with it.

**Shells.** dsh is the built-in shell and the default. The session runs every line through a
`ShellProvider` (dabterm/Shell/ShellProvider.swift), so other shells can be compiled in: a shell
does its own parsing and control flow and runs the app's commands as its programs. `chsh` lists
them and switches; Settings has the same picker. A shell missing from a build (its framework not
bundled) is listed but cannot be selected, and dsh is used. The Go framework brings `bash`: a
bash-syntax shell (mvdan/sh) with functions, loops, `$(...)`, heredocs, globbing and arrays.
Pipes between commands are buffered there, and a plain single command still runs through dsh so
`ssh` and the REPLs keep the keyboard. `cd` and the environment stay in sync both ways.

**Go-framework tools.** Builds that bundle the Go framework also get `awk` (goawk), a full `jq`
(gojq; it replaces the path-only jq), `yq` (YAML in and out around the same jq engine), `gofmt`,
and `tar` / `zip` / `unzip` / `gzip` / `gunzip`.

**WebAssembly.** `wasm file.wasm [args]` runs WASI modules on WasmKit, a pure-Swift interpreter
(App Store safe). stdin/stdout/stderr are wired to the shell, `~` is pre-opened as `/` and the
current folder as `.`, `--dir host:guest` adds more. `.wasm` files in `~/bin` run by name and packs
can ship `"kind": "wasm"` commands. This is the path for C/C++/Rust tools compiled with wasi-sdk
(bring your own `.wasm`; no compiler runs on the phone).

**JavaScript.** `js file.js [args]`, `node -e 'code'`, `node -p expr`, piped stdin, or a REPL. Runs on
the system JavaScriptCore engine (App Store safe: nothing is downloaded or JIT-compiled) with a small
Node-flavoured runtime: `require()` for local files, JSON and plain CommonJS `node_modules`, `fs`
(sync API), `path`, `os`, `util`, `events`, `process.argv/env/exit/stdout`, timers, `fetch`,
`TextEncoder`, `btoa`. Not Node: no npm native modules, no `http.createServer`, no streams.

**openssl.** A real libcrypto (OpenSSL 3) behind an `openssl`-compatible CLI subset:
`genrsa`, `genpkey` (RSA/EC/Ed25519), `ecparam -genkey`, `req` (`-new`, `-x509`, `-addext`, SANs),
`x509` (`-text`, `-subject`, `-dates`, `-fingerprint`, `-req -CA/-CAkey` signing, DER out),
`rsa`/`pkey`/`ec`, `pkcs12 -export`, `verify`, `enc` (AES-CBC/CTR with PBKDF2), `dgst`, `rand`,
`prime`, `s_client -connect` (dumps the chain and negotiated protocol).

**SSH.** Pure-Swift client (Citadel / SwiftNIO SSH). Reads `~/ssh/config` (Host, HostName, User, Port,
IdentityFile, wildcards, Include), tries keys in `~/ssh`, falls back to password, trust-on-first-use
`known_hosts`. Interactive PTY with resize, remote commands (`ssh host uptime`), `scp` over SFTP,
`ssh-copy-id`, `ssh-keygen -t ed25519`. The SSH tab lists hosts for one-tap connect and manages keys.

**Opening files.** `edit file`, `edit file:line`, `edit folder` (also `vim`, `vi`, `nano`, `code`).
dabterm registers as a handler for source, text and generic files, so it appears in the share sheet
and in Files' "Open in…". Files from outside the sandbox are copied to `~/inbox`. URL scheme for
Shortcuts and other apps: `dabterm://open?path=~/x.md&line=10`, `dabterm://run?cmd=ls`,
`dabterm://ssh?host=myserver`.

**Editor.** CodeMirror 6 in a web view with syntax highlighting for ~25 languages, search/replace,
undo/redo, go-to-line, line wrapping, tabs, a file tree with create/rename/delete/share, and a
Source Control panel. The iOS keyboard's space-bar trackpad works for moving the cursor.

**Key bar.** Above the keyboard in both the terminal and the editor: **sel**, **copy**, cut (editor),
paste, Esc, Tab, sticky Ctrl and Alt, arrows (long-press to repeat), Home/End,
`- / | ~ \` ' " { } [ ] < > $ &`, **all**, hide keyboard.

**Selecting text on a touch screen.** Tap **sel** and drag anywhere to highlight, across as many lines
as you like, then tap **copy**. No long-press, no handles. In the editor, arrows extend the selection
while sel is on, and cut/paste work on it. **all** selects everything; **copy** with nothing selected
copies the whole terminal scrollback. The terminal's native long-press menu and the editor's native
long-press selection still work too.

**git.** `git clone owner/repo`, `status`, `add`, `commit -m` (commits *and* pushes), `pull`, `log`,
`branch`, `checkout [-b]`, `diff`, `show HEAD:path`, `remote -v`, `git init owner/repo` to link an
existing folder. `gh auth login` (device flow or paste a token), `gh auth install` (the device
login is a GitHub App: it only reaches repositories the app is installed on, this opens the install page), `gh repo list|create|view`,
`gh pr list|create`, `gh issue list`. Tokens go in the Keychain, never in the Files folder.

## Tool packs (update tools without an app update)

Commands can live outside the binary as **packs**: a folder with a `pack.json` plus JavaScript
(run on JavaScriptCore) or dsh scripts. The App Store permits JavaScript loaded at runtime through
JavaScriptCore, so packs can be installed and updated out of band on production builds; native code
and WebAssembly cannot be, which is why those stay bundled.

```
pack list                                  # bundled + installed packs and their commands
pack install owner/repo[/dir]              # from GitHub (any branch: owner/repo@branch/dir)
pack install https://host/path/pack.json   # from any web server (files listed in "files")
pack update [name]                         # re-fetch from the recorded source
pack new mytools                           # scaffold ~/packs/mytools, edit it in the editor
pack reload                                # after editing a pack in place
```

Resolution order: built-in commands, then `~/packs/*` (Files → dabterm → packs), then packs bundled
in the app. A user pack with the same name as a bundled one overrides it, so a hotfix can be pushed
as a pack and later folded into a release. `scripts/sync-packs.sh` refreshes the bundled packs from
a packs repository before a release build.

A pack command is a plain script: arguments in `process.argv.slice(2)`, piped input from
`readStdin()`, the invoking name in `process.env.DABTERM_CMD` (one script can back several commands),
exit status via `process.exit(n)`. See `dabterm/Resources/packs/core-tools` for examples
(`jsonfmt`, `urlencode`, `ts`, `calc`).

`pack.json`:

```json
{
  "name": "core-tools", "version": "1.0.0", "description": "…",
  "source": "dabbers/dabterm/dabterm/Resources/packs/core-tools",
  "commands": [
    { "name": "jsonfmt", "kind": "js", "entry": "jsonfmt.js", "summary": "…", "usage": "jsonfmt [-c] [-s] [file]" },
    { "name": "hr",      "kind": "sh", "entry": "hr.sh" }
  ]
}
```

## How git works here (read this)

iOS can't run git, so v1 talks to the **GitHub Git Data API** directly: clone downloads the tree
and blobs, `status`/`diff` compare blob hashes locally, and `commit` creates blobs → tree → commit
and moves the branch ref in one step. State lives in `.dabgit/state.json` inside each clone.

Consequences:

- Works only with GitHub-hosted repos. Commits are pushed immediately (no local-only commits).
- `pull` is fast-forward only; it refuses to overwrite local edits unless `--force`.
- Very large repos (>100k tree entries) are refused by the API.
- A native `libgit2` backend (any remote, local commits, real merges) is the planned follow-up.

## Build

Requirements: Xcode 16+ (iOS 18 deployment target), [xcodegen](https://github.com/yonaskolb/XcodeGen),
Node 18+ (only to rebuild the editor bundle).

```bash
brew install xcodegen
scripts/fetch-python.sh        # optional: bundle CPython 3.13 (~35 MB download)
scripts/build-go.sh            # optional: bundle the Go interpreter (needs Go 1.21+, builds gobridge/ with gomobile)
xcodegen generate
open dabterm.xcodeproj
```

Select your team under Signing, pick a device or simulator, run.

Command line:

```bash
xcodebuild -project dabterm.xcodeproj -scheme dabterm \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro Max' \
  build
```

Rebuild the editor after changing `dabterm/Editor/web/src/editor.js`:

```bash
cd dabterm/Editor/web && npm install && npm run build
```

### Smoke test in the simulator

Launching with `DABTERM_SMOKE` runs commands at startup and writes output to `Documents/smoke.log`
in the app container:

```bash
SIMCTL_CHILD_DABTERM_SMOKE='help;;ping -c 2 1.1.1.1;;openssl rand -hex 8' \
  xcrun simctl launch booted com.dab.dabterm
cat "$(xcrun simctl get_app_container booted com.dab.dabterm data)/Documents/smoke.log"
```

`DABTERM_TAB=editor|hosts|settings` and `DABTERM_OPEN=path` open a tab or file on launch.

## Layout

```
dabterm/
  App/        app entry, tab bar, shared model, smoke-test hook
  Terminal/   SwiftTerm wrapper, key bar
  Shell/      session, line editor, tokenizer, command registry, Commands/, Packs/
  Network/    ICMP (ping/traceroute), DNS client
  Crypto/     openssl command adapter, hash commands
  SSH/        ssh_config parser, key loading/generation, ssh/scp/ssh-keygen, Hosts UI
  Editor/     CodeMirror web view, file tree, source-control panel, web/ (JS source)
  Git/        GitHub API client, GitHub-backed repo model, Keychain
  Files/      Documents-folder workspace helpers
  Settings/
  Resources/packs/   packs bundled with the app (see Tool packs)
scripts/sync-packs.sh  refresh bundled packs from a packs repo before a release
Packages/DabCrypto/   libcrypto code in its own module (see note below)
Packages/SwiftTerm/   vendored SwiftTerm 1.99.3 + one extension file exposing selection for the sel key
Vendor/python-ios/    Python.xcframework (gitignored; scripts/fetch-python.sh)
Vendor/go-ios/        Yaegi.xcframework (gitignored; scripts/build-go.sh)
gobridge/             Go side of the `go` command: Yaegi wrapped for gomobile
scripts/install-python-stdlib.sh   Xcode build phase: copies the stdlib and converts .so modules to frameworks
```

DabCrypto is a separate Swift package because OpenSSL and BoringSSL (used by SwiftNIO SSH) declare
conflicting C structs; keeping OpenSSL behind an implementation-only import avoids the clash.

## Dependencies

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) · [Citadel](https://github.com/orlandos-nl/Citadel)
· [OpenSSL xcframework](https://github.com/krzyzanowskim/OpenSSL) · [CodeMirror 6](https://codemirror.net)
· [WasmKit](https://github.com/swiftwasm/WasmKit) · [Python-Apple-support](https://github.com/beeware/Python-Apple-support)

## Roadmap

- libgit2 backend (non-GitHub remotes, local commits, merge/rebase, submodules)
- Passphrase-protected key generation, ECDSA keys, SSH agent forwarding, port forwarding (`-L`/`-R`)
- Mosh-style reconnect, tmux-aware session restore
- `openssl` SKI/AKI extensions and `s_client -starttls`
- iPad: split view terminal + editor, external keyboard shortcuts, Stage Manager multi-window
- `pip`-style installer for pure-Python wheels into `~/site-packages`
- Ship a starter set of WASI tools (e.g. jq, ripgrep builds) as a pack
- A real Node is not feasible on iOS (needs JIT and fork); QuickJS for ES modules is the next JS step

## License

MIT
