package yaegi

// A git command on go-git: real repositories with history, kept in .git like everywhere else.
// HTTPS remotes on github.com authenticate with the app's token; other remotes use the SSH keys
// in the app's ssh folder.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/go-git/go-git/v5"
	"github.com/go-git/go-git/v5/config"
	"github.com/go-git/go-git/v5/plumbing"
	"github.com/go-git/go-git/v5/plumbing/object"
	"github.com/go-git/go-git/v5/plumbing/transport"
	"github.com/go-git/go-git/v5/plumbing/transport/http"
	gitssh "github.com/go-git/go-git/v5/plumbing/transport/ssh"
	"github.com/sergi/go-diff/diffmatchpatch"
	"golang.org/x/crypto/ssh"
)

// GitConfig carries what the shell knows: the working directory, GitHub token, SSH key folder and
// the user identity for commits.
type GitConfig struct {
	Cwd, Token, UserName, UserEmail string
	// SSHKey is the private key text (from the app's Keychain) and SSHKeyName its name.
	SSHKey, SSHKeyName string
}

func NewGitConfig() *GitConfig { return &GitConfig{} }

type gitCtx struct {
	cfg *GitConfig
	out io.Writer
	err io.Writer
}

// Git runs one git command (args "\x00"-joined, without "git") and returns the exit status.
func Git(args string, cfg *GitConfig, out, errOut Output) int {
	c := &gitCtx{cfg: cfg, out: writer{out}, err: writer{errOut}}
	argv := split0(args)
	if len(argv) == 0 {
		fmt.Fprintln(c.err, "usage: git <clone|init|status|add|rm|commit|log|diff|show|branch|checkout|switch|merge|pull|fetch|push|remote|tag|reset|config|rev-parse> ...")
		return 2
	}
	if err := c.run(argv[0], argv[1:]); err != nil {
		fmt.Fprintln(c.err, "git:", err)
		return 1
	}
	return 0
}

func (c *gitCtx) auth(url string) (transport.AuthMethod, error) {
	switch {
	case strings.HasPrefix(url, "https://"), strings.HasPrefix(url, "http://"):
		if c.cfg.Token != "" && strings.Contains(url, "github.com") {
			return &http.BasicAuth{Username: "x-access-token", Password: c.cfg.Token}, nil
		}
		return nil, nil
	case strings.HasPrefix(url, "git@"), strings.HasPrefix(url, "ssh://"):
		if c.cfg.SSHKey == "" {
			return nil, errors.New("no SSH key (id_ed25519, id_ecdsa or id_rsa); ssh-keygen makes one")
		}
		keys, err := gitssh.NewPublicKeys("git", []byte(c.cfg.SSHKey), "")
		if err != nil {
			return nil, fmt.Errorf("%s: %v (passphrase-protected keys are not supported here)", c.cfg.SSHKeyName, err)
		}
		keys.HostKeyCallback = ssh.InsecureIgnoreHostKey() //nolint: host keys are checked by the ssh command, not here
		return keys, nil
	}
	return nil, nil
}

func (c *gitCtx) open() (*git.Repository, error) {
	r, err := git.PlainOpenWithOptions(c.cfg.Cwd, &git.PlainOpenOptions{DetectDotGit: true})
	if err != nil {
		return nil, errors.New("not a git repository (or any parent)")
	}
	return r, nil
}

func (c *gitCtx) signature() *object.Signature {
	name, email := c.cfg.UserName, c.cfg.UserEmail
	if name == "" {
		name = "dabterm"
	}
	if email == "" {
		email = "dabterm@localhost"
	}
	return &object.Signature{Name: name, Email: email, When: time.Now()}
}

func flag(args []string, names ...string) bool {
	for _, a := range args {
		for _, n := range names {
			if a == n {
				return true
			}
		}
	}
	return false
}

func optValue(args []string, name string) (string, []string) {
	for i, a := range args {
		if a == name && i+1 < len(args) {
			return args[i+1], append(append([]string{}, args[:i]...), args[i+2:]...)
		}
		if strings.HasPrefix(a, name+"=") {
			return strings.TrimPrefix(a, name+"="), append(append([]string{}, args[:i]...), args[i+1:]...)
		}
	}
	return "", args
}

func positional(args []string) []string {
	var out []string
	for _, a := range args {
		if !strings.HasPrefix(a, "-") {
			out = append(out, a)
		}
	}
	return out
}

func (c *gitCtx) remoteURL(r *git.Repository, name string) (string, error) {
	rem, err := r.Remote(name)
	if err != nil {
		return "", fmt.Errorf("no remote %q", name)
	}
	if len(rem.Config().URLs) == 0 {
		return "", fmt.Errorf("remote %q has no URL", name)
	}
	return rem.Config().URLs[0], nil
}

func expandURL(s string) string {
	// owner/repo shorthand means GitHub.
	if !strings.Contains(s, "://") && !strings.HasPrefix(s, "git@") && strings.Count(s, "/") == 1 && !strings.HasPrefix(s, ".") && !strings.HasPrefix(s, "/") {
		return "https://github.com/" + s + ".git"
	}
	return s
}

func (c *gitCtx) run(sub string, args []string) error {
	switch sub {
	case "clone":
		branch, args := optValue(args, "-b")
		depthStr, args := optValue(args, "--depth")
		pos := positional(args)
		if len(pos) == 0 {
			return errors.New("usage: git clone <url|owner/repo> [dir] [-b branch] [--depth n]")
		}
		url := expandURL(pos[0])
		dir := strings.TrimSuffix(filepath.Base(strings.TrimSuffix(url, "/")), ".git")
		if len(pos) > 1 {
			dir = pos[1]
		}
		dest := filepath.Join(c.cfg.Cwd, dir)
		auth, err := c.auth(url)
		if err != nil {
			return err
		}
		opts := &git.CloneOptions{URL: url, Auth: auth, Progress: c.err}
		if branch != "" {
			opts.ReferenceName = plumbing.NewBranchReferenceName(branch)
		}
		if depthStr != "" {
			opts.Depth, _ = strconv.Atoi(depthStr)
		}
		fmt.Fprintf(c.out, "Cloning into '%s'...\n", dir)
		if _, err := git.PlainClone(dest, false, opts); err != nil {
			os.RemoveAll(dest)
			return err
		}
		return nil

	case "init":
		dir := c.cfg.Cwd
		if p := positional(args); len(p) > 0 {
			dir = filepath.Join(c.cfg.Cwd, p[0])
		}
		if _, err := git.PlainInitWithOptions(dir, &git.PlainInitOptions{InitOptions: git.InitOptions{DefaultBranch: plumbing.NewBranchReferenceName("main")}}); err != nil {
			return err
		}
		fmt.Fprintf(c.out, "Initialized empty Git repository in %s/.git/\n", dir)
		return nil
	}

	r, err := c.open()
	if err != nil {
		return err
	}
	w, err := r.Worktree()
	if err != nil {
		return err
	}

	switch sub {
	case "status":
		return c.status(r, w, flag(args, "-s", "--short"))
	case "add":
		if flag(args, "-A", "--all") || (len(positional(args)) == 1 && positional(args)[0] == ".") {
			return w.AddWithOptions(&git.AddOptions{All: true})
		}
		if flag(args, "-u") {
			st, err := w.Status()
			if err != nil {
				return err
			}
			for p, s := range st {
				if s.Worktree == git.Modified || s.Worktree == git.Deleted {
					if _, err := w.Add(p); err != nil {
						return err
					}
				}
			}
			return nil
		}
		for _, p := range positional(args) {
			if _, err := w.Add(p); err != nil {
				return fmt.Errorf("%s: %v", p, err)
			}
		}
		return nil
	case "rm":
		for _, p := range positional(args) {
			if _, err := w.Remove(p); err != nil {
				return fmt.Errorf("%s: %v", p, err)
			}
			if !flag(args, "--cached") {
				os.Remove(filepath.Join(w.Filesystem.Root(), p))
			}
		}
		return nil
	case "commit":
		// -am / -ma: combined short flags.
		var expanded []string
		for _, a := range args {
			if len(a) > 2 && a[0] == '-' && a[1] != '-' && strings.Trim(a[1:], "am") == "" {
				for _, ch := range a[1:] {
					expanded = append(expanded, "-"+string(ch))
				}
			} else {
				expanded = append(expanded, a)
			}
		}
		args = expanded
		msg, rest := optValue(args, "-m")
		if msg == "" {
			return errors.New("a message is required: git commit -m 'message'")
		}
		opts := &git.CommitOptions{Author: c.signature(), All: flag(rest, "-a", "--all"), Amend: flag(rest, "--amend")}
		h, err := w.Commit(msg, opts)
		if err != nil {
			return err
		}
		head, _ := r.Head()
		fmt.Fprintf(c.out, "[%s %s] %s\n", head.Name().Short(), h.String()[:7], strings.SplitN(msg, "\n", 2)[0])
		return nil
	case "log":
		nStr, rest := optValue(args, "-n")
		n := 0
		if nStr != "" {
			n, _ = strconv.Atoi(nStr)
		}
		for _, a := range rest {
			if strings.HasPrefix(a, "-") && len(a) > 1 {
				if v, err := strconv.Atoi(a[1:]); err == nil {
					n = v
				}
			}
		}
		oneline := flag(rest, "--oneline")
		it, err := r.Log(&git.LogOptions{})
		if err != nil {
			return err
		}
		count := 0
		err = it.ForEach(func(cm *object.Commit) error {
			if n > 0 && count >= n {
				return storerStop
			}
			count++
			if oneline {
				fmt.Fprintf(c.out, "\x1b[33m%s\x1b[0m %s\n", cm.Hash.String()[:7], strings.SplitN(cm.Message, "\n", 2)[0])
			} else {
				fmt.Fprintf(c.out, "\x1b[33mcommit %s\x1b[0m\nAuthor: %s <%s>\nDate:   %s\n\n    %s\n\n", cm.Hash, cm.Author.Name, cm.Author.Email, cm.Author.When.Format(time.RFC1123Z), strings.ReplaceAll(strings.TrimRight(cm.Message, "\n"), "\n", "\n    "))
			}
			return nil
		})
		// A shallow clone ends where the history was cut; that is not an error.
		if errors.Is(err, storerStop) || errors.Is(err, plumbing.ErrObjectNotFound) {
			return nil
		}
		return err
	case "diff":
		return c.diff(r, w, args)
	case "show":
		return c.show(r, args)
	case "branch":
		return c.branch(r, w, args)
	case "checkout", "switch":
		return c.checkout(r, w, args)
	case "merge":
		pos := positional(args)
		if len(pos) == 0 {
			return errors.New("usage: git merge <branch>")
		}
		ref, err := r.Reference(plumbing.NewBranchReferenceName(pos[0]), true)
		if err != nil {
			ref, err = r.Reference(plumbing.NewRemoteReferenceName("origin", pos[0]), true)
			if err != nil {
				return fmt.Errorf("no branch %q", pos[0])
			}
		}
		if err := r.Merge(*ref, git.MergeOptions{Strategy: git.FastForwardMerge}); err != nil {
			return fmt.Errorf("%v (only fast-forward merges are supported here)", err)
		}
		fmt.Fprintln(c.out, "Fast-forwarded to", ref.Hash().String()[:7])
		return nil
	case "fetch":
		url, err := c.remoteURL(r, "origin")
		if err != nil {
			return err
		}
		auth, err := c.auth(url)
		if err != nil {
			return err
		}
		err = r.Fetch(&git.FetchOptions{RemoteName: "origin", Auth: auth, Progress: c.err, Prune: flag(args, "-p", "--prune")})
		if errors.Is(err, git.NoErrAlreadyUpToDate) {
			fmt.Fprintln(c.out, "Already up to date.")
			return nil
		}
		return err
	case "pull":
		url, err := c.remoteURL(r, "origin")
		if err != nil {
			return err
		}
		auth, err := c.auth(url)
		if err != nil {
			return err
		}
		err = w.Pull(&git.PullOptions{RemoteName: "origin", Auth: auth, Progress: c.err})
		if errors.Is(err, git.NoErrAlreadyUpToDate) {
			fmt.Fprintln(c.out, "Already up to date.")
			return nil
		}
		if err != nil {
			return fmt.Errorf("%v (only fast-forward pulls are supported here; commit or stash first)", err)
		}
		head, _ := r.Head()
		fmt.Fprintln(c.out, "Updated to", head.Hash().String()[:7])
		return nil
	case "push":
		return c.push(r, args)
	case "remote":
		return c.remote(r, args)
	case "tag":
		pos := positional(args)
		if len(pos) == 0 {
			tags, err := r.Tags()
			if err != nil {
				return err
			}
			var names []string
			tags.ForEach(func(ref *plumbing.Reference) error { names = append(names, ref.Name().Short()); return nil })
			sort.Strings(names)
			for _, n := range names {
				fmt.Fprintln(c.out, n)
			}
			return nil
		}
		if flag(args, "-d") {
			return r.DeleteTag(pos[0])
		}
		head, err := r.Head()
		if err != nil {
			return err
		}
		_, err = r.CreateTag(pos[0], head.Hash(), nil)
		return err
	case "reset":
		return c.reset(r, w, args)
	case "config":
		pos := positional(args)
		cfg, err := r.Config()
		if err != nil {
			return err
		}
		if len(pos) == 2 {
			switch pos[0] {
			case "user.name":
				cfg.User.Name = pos[1]
			case "user.email":
				cfg.User.Email = pos[1]
			default:
				return fmt.Errorf("only user.name and user.email can be set here")
			}
			return r.SetConfig(cfg)
		}
		if len(pos) == 1 {
			switch pos[0] {
			case "user.name":
				fmt.Fprintln(c.out, cfg.User.Name)
			case "user.email":
				fmt.Fprintln(c.out, cfg.User.Email)
			}
			return nil
		}
		fmt.Fprintf(c.out, "user.name=%s\nuser.email=%s\n", cfg.User.Name, cfg.User.Email)
		for name, rem := range cfg.Remotes {
			fmt.Fprintf(c.out, "remote.%s.url=%s\n", name, strings.Join(rem.URLs, " "))
		}
		return nil
	case "rev-parse":
		pos := positional(args)
		if flag(args, "--abbrev-ref") {
			head, err := r.Head()
			if err != nil {
				return err
			}
			fmt.Fprintln(c.out, head.Name().Short())
			return nil
		}
		name := "HEAD"
		if len(pos) > 0 {
			name = pos[0]
		}
		h, err := r.ResolveRevision(plumbing.Revision(name))
		if err != nil {
			return err
		}
		fmt.Fprintln(c.out, h.String())
		return nil
	case "stash":
		return errors.New("stash is not available in this git (go-git); commit to a branch instead")
	case "version", "--version":
		fmt.Fprintln(c.out, "git version 2.x-dabterm (go-git)")
		return nil
	}
	return fmt.Errorf("unknown subcommand %q", sub)
}

var storerStop = errors.New("stop")

func (c *gitCtx) status(r *git.Repository, w *git.Worktree, short bool) error {
	st, err := w.Status()
	if err != nil {
		return err
	}
	head, err := r.Head()
	branch := "(detached)"
	if err == nil && head.Name().IsBranch() {
		branch = head.Name().Short()
	}
	if short {
		paths := make([]string, 0, len(st))
		for p := range st {
			paths = append(paths, p)
		}
		sort.Strings(paths)
		for _, p := range paths {
			s := st[p]
			fmt.Fprintf(c.out, "%c%c %s\n", code(s.Staging), code(s.Worktree), p)
		}
		return nil
	}
	fmt.Fprintf(c.out, "On branch %s\n", branch)
	var staged, unstaged, untracked []string
	for p, s := range st {
		if s.Staging != git.Unmodified && s.Staging != git.Untracked {
			staged = append(staged, fmt.Sprintf("\t%s:   %s", statusWord(s.Staging), p))
		}
		if s.Worktree == git.Untracked {
			untracked = append(untracked, "\t"+p)
		} else if s.Worktree != git.Unmodified {
			unstaged = append(unstaged, fmt.Sprintf("\t%s:   %s", statusWord(s.Worktree), p))
		}
	}
	sort.Strings(staged)
	sort.Strings(unstaged)
	sort.Strings(untracked)
	if len(staged) > 0 {
		fmt.Fprintf(c.out, "Changes to be committed:\n\x1b[32m%s\x1b[0m\n\n", strings.Join(staged, "\n"))
	}
	if len(unstaged) > 0 {
		fmt.Fprintf(c.out, "Changes not staged for commit:\n\x1b[31m%s\x1b[0m\n\n", strings.Join(unstaged, "\n"))
	}
	if len(untracked) > 0 {
		fmt.Fprintf(c.out, "Untracked files:\n\x1b[31m%s\x1b[0m\n\n", strings.Join(untracked, "\n"))
	}
	if len(staged)+len(unstaged)+len(untracked) == 0 {
		fmt.Fprintln(c.out, "nothing to commit, working tree clean")
	}
	return nil
}

func code(s git.StatusCode) byte {
	if s == git.Unmodified {
		return ' '
	}
	return byte(s)
}

func statusWord(s git.StatusCode) string {
	switch s {
	case git.Added:
		return "new file"
	case git.Deleted:
		return "deleted"
	case git.Renamed:
		return "renamed"
	case git.Copied:
		return "copied"
	default:
		return "modified"
	}
}

func (c *gitCtx) headTree(r *git.Repository) (*object.Tree, error) {
	head, err := r.Head()
	if err != nil {
		return nil, err
	}
	cm, err := r.CommitObject(head.Hash())
	if err != nil {
		return nil, err
	}
	return cm.Tree()
}

func unified(path, a, b string) string {
	dmp := diffmatchpatch.New()
	ra, rb, lines := dmp.DiffLinesToRunes(a, b)
	diffs := dmp.DiffCharsToLines(dmp.DiffMainRunes(ra, rb, false), lines)
	var buf bytes.Buffer
	fmt.Fprintf(&buf, "\x1b[1mdiff --git a/%s b/%s\n--- a/%s\n+++ b/%s\x1b[0m\n", path, path, path, path)
	for _, d := range diffs {
		for _, line := range strings.SplitAfter(d.Text, "\n") {
			if line == "" {
				continue
			}
			switch d.Type {
			case diffmatchpatch.DiffInsert:
				buf.WriteString("\x1b[32m+" + strings.TrimRight(line, "\n") + "\x1b[0m\n")
			case diffmatchpatch.DiffDelete:
				buf.WriteString("\x1b[31m-" + strings.TrimRight(line, "\n") + "\x1b[0m\n")
			default:
				buf.WriteString(" " + strings.TrimRight(line, "\n") + "\n")
			}
		}
	}
	return buf.String()
}

// diff: with no revisions, the working tree against HEAD (what you would commit with -a);
// with --cached, only what is staged; with revisions, commit against commit.
func (c *gitCtx) diff(r *git.Repository, w *git.Worktree, args []string) error {
	pos := positional(args)
	if len(pos) >= 1 && !fileExists(filepath.Join(w.Filesystem.Root(), pos[0])) {
		a, err := r.ResolveRevision(plumbing.Revision(pos[0]))
		if err != nil {
			return err
		}
		ca, err := r.CommitObject(*a)
		if err != nil {
			return err
		}
		var cb *object.Commit
		if len(pos) > 1 {
			b, err := r.ResolveRevision(plumbing.Revision(pos[1]))
			if err != nil {
				return err
			}
			cb, err = r.CommitObject(*b)
			if err != nil {
				return err
			}
		} else {
			head, _ := r.Head()
			cb, _ = r.CommitObject(head.Hash())
		}
		p, err := ca.Patch(cb)
		if err != nil {
			return err
		}
		fmt.Fprint(c.out, p.String())
		return nil
	}
	st, err := w.Status()
	if err != nil {
		return err
	}
	tree, _ := c.headTree(r)
	only := map[string]bool{}
	for _, p := range pos {
		only[p] = true
	}
	paths := make([]string, 0, len(st))
	for p := range st {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	cached := flag(args, "--cached", "--staged")
	for _, p := range paths {
		s := st[p]
		if len(only) > 0 && !only[p] {
			continue
		}
		if s.Worktree == git.Untracked || (cached && s.Staging == git.Unmodified) || (!cached && s.Worktree == git.Unmodified && s.Staging == git.Unmodified) {
			continue
		}
		var old string
		if tree != nil {
			if f, err := tree.File(p); err == nil {
				old, _ = f.Contents()
			}
		}
		var cur string
		if s.Worktree != git.Deleted {
			if b, err := os.ReadFile(filepath.Join(w.Filesystem.Root(), p)); err == nil {
				cur = string(b)
			}
		}
		fmt.Fprint(c.out, unified(p, old, cur))
	}
	return nil
}

func fileExists(p string) bool { _, err := os.Stat(p); return err == nil }

func (c *gitCtx) show(r *git.Repository, args []string) error {
	pos := positional(args)
	spec := "HEAD"
	if len(pos) > 0 {
		spec = pos[0]
	}
	if i := strings.Index(spec, ":"); i > 0 {
		h, err := r.ResolveRevision(plumbing.Revision(spec[:i]))
		if err != nil {
			return err
		}
		cm, err := r.CommitObject(*h)
		if err != nil {
			return err
		}
		f, err := cm.File(spec[i+1:])
		if err != nil {
			return err
		}
		s, err := f.Contents()
		if err != nil {
			return err
		}
		fmt.Fprint(c.out, s)
		return nil
	}
	h, err := r.ResolveRevision(plumbing.Revision(spec))
	if err != nil {
		return err
	}
	cm, err := r.CommitObject(*h)
	if err != nil {
		return err
	}
	fmt.Fprintf(c.out, "\x1b[33mcommit %s\x1b[0m\nAuthor: %s <%s>\nDate:   %s\n\n    %s\n\n", cm.Hash, cm.Author.Name, cm.Author.Email, cm.Author.When.Format(time.RFC1123Z), strings.ReplaceAll(strings.TrimRight(cm.Message, "\n"), "\n", "\n    "))
	if cm.NumParents() > 0 {
		parent, _ := cm.Parent(0)
		p, err := parent.Patch(cm)
		if err == nil {
			fmt.Fprint(c.out, p.String())
		}
	}
	return nil
}

func (c *gitCtx) branch(r *git.Repository, w *git.Worktree, args []string) error {
	pos := positional(args)
	if flag(args, "-d", "-D") && len(pos) > 0 {
		return r.Storer.RemoveReference(plumbing.NewBranchReferenceName(pos[0]))
	}
	if len(pos) > 0 {
		head, err := r.Head()
		if err != nil {
			return err
		}
		return r.Storer.SetReference(plumbing.NewHashReference(plumbing.NewBranchReferenceName(pos[0]), head.Hash()))
	}
	head, _ := r.Head()
	it, err := r.Branches()
	if err != nil {
		return err
	}
	var names []string
	it.ForEach(func(ref *plumbing.Reference) error { names = append(names, ref.Name().Short()); return nil })
	sort.Strings(names)
	for _, n := range names {
		if head != nil && head.Name().Short() == n {
			fmt.Fprintf(c.out, "* \x1b[32m%s\x1b[0m\n", n)
		} else {
			fmt.Fprintf(c.out, "  %s\n", n)
		}
	}
	if flag(args, "-a", "-r") {
		refs, _ := r.References()
		refs.ForEach(func(ref *plumbing.Reference) error {
			if ref.Name().IsRemote() {
				fmt.Fprintf(c.out, "  \x1b[31m%s\x1b[0m\n", ref.Name().Short())
			}
			return nil
		})
	}
	return nil
}

func (c *gitCtx) checkout(r *git.Repository, w *git.Worktree, args []string) error {
	create := flag(args, "-b", "-c")
	pos := positional(args)
	// git checkout -- file...: restore from HEAD.
	if i := indexOf(args, "--"); i >= 0 || (len(pos) > 0 && !create && fileExists(filepath.Join(w.Filesystem.Root(), pos[0])) && !branchExists(r, pos[0])) {
		files := pos
		if i >= 0 {
			files = args[i+1:]
		}
		tree, err := c.headTree(r)
		if err != nil {
			return err
		}
		for _, p := range files {
			f, err := tree.File(p)
			if err != nil {
				return fmt.Errorf("%s: not in HEAD", p)
			}
			s, err := f.Contents()
			if err != nil {
				return err
			}
			if err := os.WriteFile(filepath.Join(w.Filesystem.Root(), p), []byte(s), 0o644); err != nil {
				return err
			}
		}
		return nil
	}
	if len(pos) == 0 {
		return errors.New("usage: git checkout [-b] <branch>  |  git checkout -- <file>")
	}
	name := pos[0]
	ref := plumbing.NewBranchReferenceName(name)
	if !create && !branchExists(r, name) {
		// A remote branch: make a local one tracking it.
		if rref, err := r.Reference(plumbing.NewRemoteReferenceName("origin", name), true); err == nil {
			if err := r.Storer.SetReference(plumbing.NewHashReference(ref, rref.Hash())); err != nil {
				return err
			}
			cfg, _ := r.Config()
			cfg.Branches[name] = &config.Branch{Name: name, Remote: "origin", Merge: ref}
			_ = r.SetConfig(cfg)
		} else if h, err := r.ResolveRevision(plumbing.Revision(name)); err == nil {
			return w.Checkout(&git.CheckoutOptions{Hash: *h, Force: flag(args, "-f")})
		} else {
			return fmt.Errorf("no branch %q", name)
		}
	}
	if err := w.Checkout(&git.CheckoutOptions{Branch: ref, Create: create, Force: flag(args, "-f"), Keep: true}); err != nil {
		return err
	}
	fmt.Fprintf(c.out, "Switched to branch '%s'\n", name)
	return nil
}

func branchExists(r *git.Repository, name string) bool {
	_, err := r.Reference(plumbing.NewBranchReferenceName(name), false)
	return err == nil
}

func indexOf(args []string, s string) int {
	for i, a := range args {
		if a == s {
			return i
		}
	}
	return -1
}

func (c *gitCtx) push(r *git.Repository, args []string) error {
	pos := positional(args)
	remoteName := "origin"
	if len(pos) > 0 {
		remoteName = pos[0]
	}
	url, err := c.remoteURL(r, remoteName)
	if err != nil {
		return err
	}
	auth, err := c.auth(url)
	if err != nil {
		return err
	}
	head, err := r.Head()
	if err != nil {
		return err
	}
	branch := head.Name().Short()
	if len(pos) > 1 {
		branch = pos[1]
	}
	spec := config.RefSpec(fmt.Sprintf("refs/heads/%s:refs/heads/%s", branch, branch))
	if flag(args, "-f", "--force") {
		spec = config.RefSpec("+" + string(spec))
	}
	if flag(args, "--tags") {
		spec = config.RefSpec("refs/tags/*:refs/tags/*")
	}
	err = r.Push(&git.PushOptions{RemoteName: remoteName, Auth: auth, Progress: c.err, RefSpecs: []config.RefSpec{spec}})
	if errors.Is(err, git.NoErrAlreadyUpToDate) {
		fmt.Fprintln(c.out, "Everything up-to-date")
		err = nil
	}
	if err != nil {
		return err
	}
	if flag(args, "-u", "--set-upstream") {
		cfg, _ := r.Config()
		cfg.Branches[branch] = &config.Branch{Name: branch, Remote: remoteName, Merge: plumbing.NewBranchReferenceName(branch)}
		_ = r.SetConfig(cfg)
	}
	fmt.Fprintf(c.out, "Pushed %s to %s\n", branch, remoteName)
	return nil
}

func (c *gitCtx) remote(r *git.Repository, args []string) error {
	pos := positional(args)
	if len(pos) == 0 || pos[0] == "show" {
		rems, err := r.Remotes()
		if err != nil {
			return err
		}
		for _, rem := range rems {
			if flag(args, "-v") {
				for _, u := range rem.Config().URLs {
					fmt.Fprintf(c.out, "%s\t%s (fetch)\n%s\t%s (push)\n", rem.Config().Name, u, rem.Config().Name, u)
				}
			} else {
				fmt.Fprintln(c.out, rem.Config().Name)
			}
		}
		return nil
	}
	switch pos[0] {
	case "add":
		if len(pos) < 3 {
			return errors.New("usage: git remote add <name> <url>")
		}
		_, err := r.CreateRemote(&config.RemoteConfig{Name: pos[1], URLs: []string{expandURL(pos[2])}})
		return err
	case "remove", "rm":
		if len(pos) < 2 {
			return errors.New("usage: git remote remove <name>")
		}
		return r.DeleteRemote(pos[1])
	case "set-url":
		if len(pos) < 3 {
			return errors.New("usage: git remote set-url <name> <url>")
		}
		cfg, err := r.Config()
		if err != nil {
			return err
		}
		rem, ok := cfg.Remotes[pos[1]]
		if !ok {
			return fmt.Errorf("no remote %q", pos[1])
		}
		rem.URLs = []string{expandURL(pos[2])}
		return r.SetConfig(cfg)
	}
	return fmt.Errorf("unknown remote subcommand %q", pos[0])
}

func (c *gitCtx) reset(r *git.Repository, w *git.Worktree, args []string) error {
	pos := positional(args)
	mode := git.MixedReset
	if flag(args, "--hard") {
		mode = git.HardReset
	} else if flag(args, "--soft") {
		mode = git.SoftReset
	}
	// git reset <file>: unstage.
	if len(pos) > 0 && fileExists(filepath.Join(w.Filesystem.Root(), pos[0])) {
		return w.Reset(&git.ResetOptions{Mode: git.MixedReset, Files: pos})
	}
	opts := &git.ResetOptions{Mode: mode}
	if len(pos) > 0 {
		h, err := r.ResolveRevision(plumbing.Revision(pos[0]))
		if err != nil {
			return err
		}
		opts.Commit = *h
	}
	return w.Reset(opts)
}
