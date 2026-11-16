// Package yaegi wraps the Yaegi Go interpreter for dabterm's `go` command (built into an
// xcframework with gomobile; see scripts/build-go.sh). Interpreted Go on the phone: no compiler,
// no JIT, the standard library comes compiled in with the app.
package yaegi

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"reflect"
	"strings"

	"github.com/traefik/yaegi/interp"
	"github.com/traefik/yaegi/stdlib"
)

// Output receives bytes written to the program's stdout or stderr. Implemented on the Swift side.
type Output interface {
	Write(data []byte)
}

// Input supplies the program's stdin: Read returns up to max bytes, or an empty slice at EOF.
// Implemented on the Swift side.
type Input interface {
	Read(max int) ([]byte, error)
}

type writer struct{ o Output }

func (w writer) Write(p []byte) (int, error) {
	if w.o != nil {
		w.o.Write(append([]byte(nil), p...))
	}
	return len(p), nil
}

type reader struct{ i Input }

func (r reader) Read(p []byte) (int, error) {
	if r.i == nil {
		return 0, io.EOF
	}
	b, err := r.i.Read(len(p))
	if err != nil {
		return 0, err
	}
	if len(b) == 0 {
		return 0, io.EOF
	}
	return copy(p, b), nil
}

type exitCode int

// Interp is one interpreter instance: a program run, or a REPL session.
type Interp struct {
	i *interp.Interpreter
}

// New makes an interpreter. args is the program's os.Args joined with "\x00"; goPath is a folder
// whose src/ holds importable source packages; cwd is the working directory.
func New(out, errOut Output, in Input, args, goPath, cwd string) *Interp {
	argv := strings.Split(args, "\x00")
	if args == "" {
		argv = []string{"go"}
	}
	// Lets os.Stdin/os.Stdout/os.Stderr be our readers and writers rather than file descriptors.
	os.Setenv("YAEGI_SPECIAL_STDIO", "true")
	i := interp.New(interp.Options{
		Stdout: writer{out},
		Stderr: writer{errOut},
		Stdin:  reader{in},
		Args:   argv,
		GoPath: goPath,
		Env:    os.Environ(),
	})
	i.Use(stdlib.Symbols)
	// os.Exit would end the whole app: turn it into a panic that Run reports as the exit code.
	i.Use(interp.Exports{"os/os": {
		"Exit": reflect.ValueOf(func(code int) { panic(exitCode(code)) }),
	}})
	if cwd != "" {
		_ = os.Chdir(cwd)
	}
	return &Interp{i: i}
}

// RunFile evaluates a Go source file (or a directory of package main) and runs main if present.
// Returns the exit code; compile and runtime errors are reported on stderr and give 1.
func (p *Interp) RunFile(path string, errOut Output) int {
	return p.guard(errOut, func() error {
		_, err := p.i.EvalPath(path)
		return err
	})
}

// RunSource evaluates Go source text as a file; same semantics as RunFile.
func (p *Interp) RunSource(src string, errOut Output) int {
	return p.guard(errOut, func() error {
		_, err := p.i.Eval(src)
		return err
	})
}

// Eval evaluates one REPL input and returns the printed value (empty for statements).
// Errors come back as the error.
func (p *Interp) Eval(src string) (string, error) {
	var out string
	var evalErr error
	func() {
		defer func() {
			if r := recover(); r != nil {
				if c, ok := r.(exitCode); ok {
					evalErr = fmt.Errorf("exit %d", int(c))
					return
				}
				evalErr = fmt.Errorf("panic: %v", r)
			}
		}()
		v, err := p.i.Eval(src)
		if err != nil {
			var pe interp.Panic
			if errors.As(err, &pe) {
				if c, ok := pe.Value.(exitCode); ok {
					evalErr = fmt.Errorf("exit %d", int(c))
					return
				}
			}
			evalErr = err
			return
		}
		if v.IsValid() && v.Kind() != reflect.Invalid {
			switch v.Kind() {
			case reflect.Func, reflect.Chan:
			default:
				if v.CanInterface() {
					out = fmt.Sprintf("%v", v.Interface())
				}
			}
		}
	}()
	return out, evalErr
}

// Incomplete reports whether src looks like an unfinished REPL input (unbalanced braces or parens).
func Incomplete(src string) bool {
	depth := 0
	inStr, inRaw := false, false
	for i := 0; i < len(src); i++ {
		c := src[i]
		switch {
		case inRaw:
			if c == '`' {
				inRaw = false
			}
		case inStr:
			if c == '\\' {
				i++
			} else if c == '"' {
				inStr = false
			}
		case c == '`':
			inRaw = true
		case c == '"':
			inStr = true
		case c == '{' || c == '(' || c == '[':
			depth++
		case c == '}' || c == ')' || c == ']':
			depth--
		}
	}
	return depth > 0 || inStr || inRaw
}

func (p *Interp) guard(errOut Output, f func() error) (code int) {
	defer func() {
		if r := recover(); r != nil {
			if c, ok := r.(exitCode); ok {
				code = int(c)
				return
			}
			var buf bytes.Buffer
			fmt.Fprintf(&buf, "panic: %v\n", r)
			if p, ok := r.(interp.Panic); ok {
				buf.Write(p.Stack)
			}
			errOut.Write(buf.Bytes())
			code = 2
		}
	}()
	if err := f(); err != nil {
		var pe interp.Panic
		if errors.As(err, &pe) {
			// os.Exit(n) from the program arrives here as a panic carrying the code.
			if c, ok := pe.Value.(exitCode); ok {
				return int(c)
			}
			errOut.Write([]byte(fmt.Sprintf("panic: %v\n%s", pe.Value, pe.Stack)))
		} else {
			errOut.Write([]byte(err.Error() + "\n"))
		}
		return 1
	}
	return 0
}
