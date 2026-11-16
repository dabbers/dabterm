import Foundation

/// `pip`: installs pure-Python packages from PyPI into ~/site-packages, where the bundled Python
/// already looks. Only wheels tagged `py3-none-any` (or `py2.py3-none-any`) qualify: anything
/// with compiled extensions cannot be loaded on iOS. Dependencies from the wheel's metadata are
/// installed too. The work is a Python script run by the embedded interpreter.
struct PipCommand: Command {
    let name = "pip"; let usage = "pip install pkg[==version]...  |  pip uninstall pkg  |  pip list  |  pip show pkg"
    let summary = "install pure-Python packages from PyPI into ~/site-packages"
    func run(_ ctx: CommandContext) async throws -> Int32 {
        guard let sub = ctx.args.first, ["install", "uninstall", "list", "show", "freeze"].contains(sub) else { throw CommandError("usage: \(usage)") }
        let rest = Array(ctx.args.dropFirst()).filter { !$0.hasPrefix("-") }
        let upgrade = ctx.args.contains("--upgrade") || ctx.args.contains("-U")
        let site = Workspace.root.appendingPathComponent("site-packages").path
        let script = Self.script
        let argv = ["-c", script, sub, site, upgrade ? "1" : "0"] + rest
        return try await PythonCommand().run(await ctx.derived(name: "python", args: argv))
    }

    static let script = #"""
import sys, os, json, re, zipfile, io, shutil, urllib.request, urllib.parse
sub, site, upgrade, *names = sys.argv[1:]
os.makedirs(site, exist_ok=True)
UA = {"User-Agent": "dabterm-pip/1"}

def norm(n): return re.sub(r"[-_.]+", "-", n).lower()
def installed():
    out = {}
    for d in os.listdir(site):
        if d.endswith(".dist-info"):
            m = re.match(r"(.+?)-([^-]+)\.dist-info$", d)
            if m: out[norm(m.group(1))] = (m.group(1), m.group(2), os.path.join(site, d))
    return out
def fetch(url):
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r: return r.read()
def pick(info, want):
    rels = info["releases"]; ver = want or info["info"]["version"]
    if ver not in rels: raise SystemExit(f"error: no release {ver} (have {', '.join(sorted(rels)[-5:])})")
    for f in rels[ver]:
        if f["packagetype"] == "bdist_wheel" and f["filename"].endswith(("py3-none-any.whl", "py2.py3-none-any.whl")) and not f.get("yanked"):
            return ver, f
    raise SystemExit(f"error: {info['info']['name']} {ver} has no pure-Python wheel (compiled packages cannot run on iOS)")
def requires(metadata):
    deps = []
    for line in metadata.splitlines():
        if line.startswith("Requires-Dist:"):
            spec = line.split(":", 1)[1].strip()
            if ";" in spec:
                spec, marker = spec.split(";", 1)
                if "extra" in marker: continue
            m = re.match(r"([A-Za-z0-9_.\-]+)", spec)
            if m: deps.append(m.group(1))
    return deps
def install(spec, seen):
    m = re.match(r"([A-Za-z0-9_.\-]+)\s*(?:==\s*([^\s]+))?", spec)
    if not m: raise SystemExit(f"error: bad requirement {spec!r}")
    name, want = m.group(1), m.group(2)
    key = norm(name)
    if key in seen: return
    seen.add(key)
    have = installed()
    if key in have and not want and not upgrade: print(f"{have[key][0]} {have[key][1]} already installed"); return
    info = json.loads(fetch(f"https://pypi.org/pypi/{urllib.parse.quote(name)}/json"))
    ver, f = pick(info, want)
    print(f"Downloading {f['filename']} ({f['size']//1024} KB)")
    data = fetch(f["url"])
    if key in have: shutil.rmtree(have[key][2], ignore_errors=True)
    z = zipfile.ZipFile(io.BytesIO(data))
    meta = ""
    for n in z.namelist():
        if n.endswith(".dist-info/METADATA"): meta = z.read(n).decode("utf-8", "replace")
    # Record what came from the wheel so uninstall can remove exactly that.
    z.extractall(site)
    rec = [n for n in z.namelist()]
    for n in z.namelist():
        if n.endswith(".dist-info/"): pass
    distinfo = [n for n in z.namelist() if n.endswith(".dist-info/METADATA")]
    if distinfo:
        with open(os.path.join(site, os.path.dirname(distinfo[0]), "INSTALLER"), "w") as fh: fh.write("dabterm\n")
    print(f"Installed {info['info']['name']} {ver}")
    for d in requires(meta): install(d, seen)

if sub == "install":
    if not names: raise SystemExit("usage: pip install pkg[==version]...")
    seen = set()
    for n in names: install(n, seen)
elif sub == "uninstall":
    have = installed()
    for n in names:
        k = norm(n)
        if k not in have: print(f"{n}: not installed"); continue
        rec = os.path.join(have[k][2], "RECORD")
        removed = 0
        if os.path.exists(rec):
            for line in open(rec, encoding="utf-8"):
                p = line.split(",")[0]
                fp = os.path.join(site, p)
                if os.path.isfile(fp): os.remove(fp); removed += 1
        shutil.rmtree(have[k][2], ignore_errors=True)
        for d in os.listdir(site):
            dp = os.path.join(site, d)
            if os.path.isdir(dp) and not os.listdir(dp): os.rmdir(dp)
        print(f"Uninstalled {have[k][0]} {have[k][1]} ({removed} files)")
elif sub in ("list", "freeze"):
    for k, (n, v, _) in sorted(installed().items()):
        print(f"{n}=={v}" if sub == "freeze" else f"{n} {v}")
elif sub == "show":
    have = installed()
    for n in names:
        k = norm(n)
        if k not in have: print(f"{n}: not installed"); continue
        print(open(os.path.join(have[k][2], "METADATA"), encoding="utf-8", errors="replace").read().split("\n\n", 1)[0])
"""#
}
