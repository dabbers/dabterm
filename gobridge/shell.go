package yaegi

import (
	"context"
	"errors"
	"io"
	"os"
	"strings"

	"mvdan.cc/sh/v3/expand"
	"mvdan.cc/sh/v3/interp"
	"mvdan.cc/sh/v3/syntax"
)

// Exec runs one of the app's commands for the shell: name, its arguments ("\x00"-joined), what to
// feed it as stdin (nil when the command should see no input), and where its output goes.
// Returns the exit status. Implemented on the Swift side.
type Exec interface {
	Run(name string, args string, stdin []byte, hasStdin bool, out Output, errOut Output) int
}

// Shell is a bash-syntax shell (mvdan/sh) whose "programs" are the app's commands. One per
// terminal session; variables, functions and the working directory persist between lines.
type Shell struct {
	runner *interp.Runner
	parser *syntax.Parser
	stdin  io.Reader
	stderr Output
	exec   Exec
}

// NewShell makes a shell. env is "\x00"-joined K=V pairs; cwd is the working directory.
func NewShell(exec Exec, out, errOut Output, in Input, cwd string, env string) (*Shell, error) {
	s := &Shell{parser: syntax.NewParser(syntax.Variant(syntax.LangBash)), stdin: reader{in}, stderr: errOut, exec: exec}
	handler := func(ctx context.Context, args []string) error {
		if len(args) == 0 {
			return nil
		}
		hc := interp.HandlerCtx(ctx)
		var data []byte
		has := false
		// Only drain stdin when it is a pipe from another command; the shell's own stdin is
		// the terminal, and reading it to EOF would wait for the user.
		if hc.Stdin != nil && hc.Stdin != s.stdin {
			data, _ = io.ReadAll(hc.Stdin)
			has = true
		}
		code := s.exec.Run(args[0], strings.Join(args[1:], "\x00"), data, has, nopOutput{hc.Stdout}, nopOutput{hc.Stderr})
		if code != 0 {
			return interp.NewExitStatus(uint8(code))
		}
		return nil
	}
	r, err := interp.New(
		interp.StdIO(s.stdin, writer{out}, writer{errOut}),
		interp.Dir(cwd),
		interp.Env(expand.ListEnviron(splitEnv(env)...)),
		interp.ExecHandlers(func(next interp.ExecHandlerFunc) interp.ExecHandlerFunc { return handler }),
	)
	if err != nil {
		return nil, err
	}
	s.runner = r
	return s, nil
}

// nopOutput adapts a Go writer to the Output interface used by the bridge's writer type.
type nopOutput struct{ w io.Writer }

func (n nopOutput) Write(data []byte) {
	if n.w != nil {
		_, _ = n.w.Write(data)
	}
}

func splitEnv(env string) []string {
	if env == "" {
		return os.Environ()
	}
	return strings.Split(env, "\x00")
}

// Run parses and runs one line. Returns the exit status (also for `exit`).
func (s *Shell) Run(line string, name string) int {
	return s.run(strings.NewReader(line), name)
}

// RunScript runs a whole script with $0 and positional parameters set.
func (s *Shell) RunScript(src, name, args string) int {
	params := []string{}
	if args != "" {
		params = strings.Split(args, "\x00")
	}
	s.runner.Params = params
	defer func() { s.runner.Params = nil }()
	return s.run(strings.NewReader(src), name)
}

func (s *Shell) run(src io.Reader, name string) int {
	file, err := s.parser.Parse(src, name)
	if err != nil {
		s.stderr.Write([]byte(err.Error() + "\n"))
		return 2
	}
	err = s.runner.Run(context.Background(), file)
	if err == nil {
		return 0
	}
	var status interp.ExitStatus
	if errors.As(err, &status) {
		return int(status)
	}
	s.stderr.Write([]byte(err.Error() + "\n"))
	return 1
}

// Incomplete reports whether src needs more lines (an unfinished compound command or quote).
func (s *Shell) Incomplete(src string) bool {
	_, err := s.parser.Parse(strings.NewReader(src), "")
	return err != nil && syntax.IsIncomplete(err)
}

// Dir is the shell's current directory (cd changes it); SetDir syncs it from the app.
func (s *Shell) Dir() string        { return s.runner.Dir }
func (s *Shell) SetDir(dir string)  { s.runner.Dir = dir }
func (s *Shell) SetEnv(env string)  { _ = interp.Env(expand.ListEnviron(splitEnv(env)...))(s.runner) }
func (s *Shell) Exited() bool       { return s.runner.Exited() }
