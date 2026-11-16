package yaegi

// Pure-Go developer tools compiled into the app's Go framework and exposed to the shell:
// awk (goawk), jq (gojq), yq (YAML in and out around gojq), gofmt (go/format) and the archive
// commands tar, zip, unzip and gzip (Go's standard library).

import (
	"archive/tar"
	"archive/zip"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"go/format"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/benhoyt/goawk/interp"
	"github.com/benhoyt/goawk/parser"
	"github.com/itchyny/gojq"
	"gopkg.in/yaml.v3"
)

func split0(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, "\x00")
}

// Awk runs an AWK program. args are the input files and var=value assignments ("\x00"-joined),
// vars are -v assignments ("\x00"-joined name=value pairs). Returns the exit status.
func Awk(prog string, args string, vars string, in Input, out, errOut Output, cwd string) int {
	p, err := parser.ParseProgram([]byte(prog), nil)
	if err != nil {
		errOut.Write([]byte("awk: " + err.Error() + "\n"))
		return 2
	}
	var kv []string
	for _, v := range split0(vars) {
		if i := strings.IndexByte(v, '='); i > 0 {
			kv = append(kv, v[:i], v[i+1:])
		}
	}
	_ = os.Chdir(cwd)
	cfg := &interp.Config{
		Stdin:  reader{in},
		Output: writer{out},
		Error:  writer{errOut},
		Args:   split0(args),
		Vars:   kv,
		NoExec: true, // no system() or pipes to processes: there are none on iOS
	}
	status, err := interp.ExecProgram(p, cfg)
	if err != nil {
		errOut.Write([]byte("awk: " + err.Error() + "\n"))
		return 2
	}
	return status
}

// Gofmt formats Go source.
func Gofmt(src string) (string, error) {
	b, err := format.Source([]byte(src))
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// Jq runs a jq filter over JSON (or YAML when yamlIn) text and returns the results, one per line
// (pretty-printed unless compact; strings unquoted when raw; YAML documents when yamlOut).
func Jq(filter, input string, yamlIn, yamlOut, raw, compact bool) (string, error) {
	q, err := gojq.Parse(filter)
	if err != nil {
		return "", fmt.Errorf("jq: %v", err)
	}
	code, err := gojq.Compile(q)
	if err != nil {
		return "", fmt.Errorf("jq: %v", err)
	}
	var docs []any
	if yamlIn {
		dec := yaml.NewDecoder(strings.NewReader(input))
		for {
			var v any
			if err := dec.Decode(&v); err != nil {
				if errors.Is(err, io.EOF) {
					break
				}
				return "", fmt.Errorf("yq: %v", err)
			}
			docs = append(docs, normalizeYAML(v))
		}
	} else {
		dec := json.NewDecoder(strings.NewReader(input))
		for {
			var v any
			if err := dec.Decode(&v); err != nil {
				if errors.Is(err, io.EOF) {
					break
				}
				return "", fmt.Errorf("jq: %v", err)
			}
			docs = append(docs, v)
		}
	}
	if len(docs) == 0 && strings.TrimSpace(input) == "" {
		docs = []any{nil}
	}
	var out bytes.Buffer
	for _, d := range docs {
		iter := code.Run(d)
		for {
			v, ok := iter.Next()
			if !ok {
				break
			}
			if e, isErr := v.(error); isErr {
				return out.String(), fmt.Errorf("jq: %v", e)
			}
			switch {
			case raw && isString(v):
				out.WriteString(v.(string) + "\n")
			case yamlOut:
				b, err := yaml.Marshal(v)
				if err != nil {
					return out.String(), err
				}
				out.Write(b)
				if len(docs) > 1 {
					out.WriteString("---\n")
				}
			default:
				enc := json.NewEncoder(&out)
				enc.SetEscapeHTML(false)
				if !compact {
					enc.SetIndent("", "  ")
				}
				if err := enc.Encode(v); err != nil {
					return out.String(), err
				}
			}
		}
	}
	return out.String(), nil
}

func isString(v any) bool { _, ok := v.(string); return ok }

// yaml.v3 decodes mappings with interface{} keys; jq wants string keys.
func normalizeYAML(v any) any {
	switch t := v.(type) {
	case map[string]any:
		for k, x := range t {
			t[k] = normalizeYAML(x)
		}
		return t
	case map[any]any:
		m := make(map[string]any, len(t))
		for k, x := range t {
			m[fmt.Sprint(k)] = normalizeYAML(x)
		}
		return m
	case []any:
		for i, x := range t {
			t[i] = normalizeYAML(x)
		}
		return t
	}
	return v
}

// Tar: op is "c" (create), "x" (extract) or "t" (list); archive is the file ("-" for stdout is
// not supported); files ("\x00"-joined) are relative to cwd; dest is the extraction directory.
func Tar(op, archive, files, cwd, dest string, gz, verbose bool, out Output) error {
	_ = os.Chdir(cwd)
	switch op {
	case "c":
		f, err := os.Create(archive)
		if err != nil {
			return err
		}
		defer f.Close()
		var w io.Writer = f
		var gzw *gzip.Writer
		if gz {
			gzw = gzip.NewWriter(f)
			w = gzw
		}
		tw := tar.NewWriter(w)
		for _, name := range split0(files) {
			err := filepath.Walk(name, func(path string, info os.FileInfo, err error) error {
				if err != nil {
					return err
				}
				hdr, err := tar.FileInfoHeader(info, "")
				if err != nil {
					return err
				}
				hdr.Name = filepath.ToSlash(path)
				if info.IsDir() {
					hdr.Name += "/"
				}
				if verbose {
					out.Write([]byte(hdr.Name + "\n"))
				}
				if err := tw.WriteHeader(hdr); err != nil {
					return err
				}
				if info.Mode().IsRegular() {
					src, err := os.Open(path)
					if err != nil {
						return err
					}
					_, err = io.Copy(tw, src)
					src.Close()
					return err
				}
				return nil
			})
			if err != nil {
				return err
			}
		}
		if err := tw.Close(); err != nil {
			return err
		}
		if gzw != nil {
			return gzw.Close()
		}
		return nil
	case "x", "t":
		f, err := os.Open(archive)
		if err != nil {
			return err
		}
		defer f.Close()
		var r io.Reader = f
		if gz || strings.HasSuffix(archive, ".gz") || strings.HasSuffix(archive, ".tgz") {
			gr, err := gzip.NewReader(f)
			if err != nil {
				return err
			}
			defer gr.Close()
			r = gr
		}
		tr := tar.NewReader(r)
		for {
			hdr, err := tr.Next()
			if errors.Is(err, io.EOF) {
				return nil
			}
			if err != nil {
				return err
			}
			if op == "t" || verbose {
				out.Write([]byte(hdr.Name + "\n"))
			}
			if op == "t" {
				continue
			}
			target := filepath.Join(dest, filepath.Clean("/"+hdr.Name))
			switch hdr.Typeflag {
			case tar.TypeDir:
				if err := os.MkdirAll(target, 0o755); err != nil {
					return err
				}
			case tar.TypeReg:
				if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
					return err
				}
				w, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, os.FileMode(hdr.Mode)&0o777|0o600)
				if err != nil {
					return err
				}
				if _, err := io.Copy(w, tr); err != nil {
					w.Close()
					return err
				}
				w.Close()
				_ = os.Chtimes(target, time.Now(), hdr.ModTime)
			}
		}
	}
	return fmt.Errorf("tar: unknown operation %q", op)
}

// Zip creates archive from files ("\x00"-joined, relative to cwd; directories recurse).
func Zip(archive, files, cwd string, verbose bool, out Output) error {
	_ = os.Chdir(cwd)
	f, err := os.Create(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	zw := zip.NewWriter(f)
	for _, name := range split0(files) {
		err := filepath.Walk(name, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.IsDir() {
				return nil
			}
			hdr, err := zip.FileInfoHeader(info)
			if err != nil {
				return err
			}
			hdr.Name = filepath.ToSlash(path)
			hdr.Method = zip.Deflate
			if verbose {
				out.Write([]byte("  adding: " + hdr.Name + "\n"))
			}
			w, err := zw.CreateHeader(hdr)
			if err != nil {
				return err
			}
			src, err := os.Open(path)
			if err != nil {
				return err
			}
			_, err = io.Copy(w, src)
			src.Close()
			return err
		})
		if err != nil {
			return err
		}
	}
	return zw.Close()
}

// Unzip extracts (or lists, when list) archive into dest.
func Unzip(archive, dest string, list bool, out Output) error {
	zr, err := zip.OpenReader(archive)
	if err != nil {
		return err
	}
	defer zr.Close()
	names := make([]string, 0, len(zr.File))
	for _, zf := range zr.File {
		names = append(names, zf.Name)
	}
	sort.Strings(names)
	for _, zf := range zr.File {
		if list {
			out.Write([]byte(fmt.Sprintf("%9d  %s  %s\n", zf.UncompressedSize64, zf.Modified.Format("2006-01-02 15:04"), zf.Name)))
			continue
		}
		target := filepath.Join(dest, filepath.Clean("/"+zf.Name))
		if zf.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o755); err != nil {
				return err
			}
			continue
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
			return err
		}
		rc, err := zf.Open()
		if err != nil {
			return err
		}
		w, err := os.OpenFile(target, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, zf.Mode()&0o777|0o600)
		if err != nil {
			rc.Close()
			return err
		}
		_, err = io.Copy(w, rc)
		w.Close()
		rc.Close()
		if err != nil {
			return err
		}
	}
	return nil
}

// Gzip compresses path to path.gz (or decompresses a .gz), removing the original unless keep.
func Gzip(path string, decompress, keep bool) error {
	if decompress {
		if !strings.HasSuffix(path, ".gz") {
			return fmt.Errorf("gzip: %s: unknown suffix", path)
		}
		src, err := os.Open(path)
		if err != nil {
			return err
		}
		defer src.Close()
		gr, err := gzip.NewReader(src)
		if err != nil {
			return err
		}
		dst, err := os.Create(strings.TrimSuffix(path, ".gz"))
		if err != nil {
			return err
		}
		if _, err := io.Copy(dst, gr); err != nil {
			dst.Close()
			return err
		}
		dst.Close()
	} else {
		src, err := os.Open(path)
		if err != nil {
			return err
		}
		defer src.Close()
		dst, err := os.Create(path + ".gz")
		if err != nil {
			return err
		}
		gw := gzip.NewWriter(dst)
		if _, err := io.Copy(gw, src); err != nil {
			dst.Close()
			return err
		}
		if err := gw.Close(); err != nil {
			dst.Close()
			return err
		}
		dst.Close()
	}
	if !keep {
		return os.Remove(path)
	}
	return nil
}
