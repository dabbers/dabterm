// hello-go: a small WASI program for dabterm.
//
// Build on a Mac (Go 1.21+):   GOOS=wasip1 GOARCH=wasm go build -o hello-go.wasm .
// Run in dabterm:              wasm hello-go.wasm 50
//                              echo "the quick brown fox" | wasm hello-go.wasm
// Or copy it to ~/bin and run it by name: hello-go 50
package main

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
	"time"
)

func primes(limit int) []int {
	sieve := make([]bool, limit+1)
	var out []int
	for i := 2; i <= limit; i++ {
		if sieve[i] {
			continue
		}
		out = append(out, i)
		for j := i * i; j <= limit; j += i {
			sieve[j] = true
		}
	}
	return out
}

func main() {
	fmt.Printf("hello from %s on %s/%s\n", runtime.Version(), runtime.GOOS, runtime.GOARCH)

	limit := 30
	if len(os.Args) > 1 {
		if n, err := strconv.Atoi(os.Args[1]); err == nil {
			limit = n
		}
	}
	start := time.Now()
	ps := primes(limit)
	fmt.Printf("%d primes up to %d: %v\n", len(ps), limit, ps)
	fmt.Printf("sieve took %v\n", time.Since(start).Round(time.Microsecond))

	// Anything piped in gets a word count, like `wc -w`. (dabterm gives the module an empty,
	// already-closed stdin when nothing is piped, so this just sees EOF then.)
	words, lines := 0, 0
	sc := bufio.NewScanner(os.Stdin)
	for sc.Scan() {
		lines++
		words += len(strings.Fields(sc.Text()))
	}
	if lines > 0 {
		fmt.Printf("stdin: %d lines, %d words\n", lines, words)
	}

	if wd, err := os.Getwd(); err == nil {
		fmt.Println("working directory:", wd)
	}
}
