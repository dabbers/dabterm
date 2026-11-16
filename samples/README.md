# Samples: Go and C++ on the phone

dabterm runs no compiler on the device. Build these on a Mac to WASI WebAssembly, copy the
`.wasm` into the app's Files folder (or `~/bin` to run them by name), and run them with `wasm`.

| Sample | Build on the Mac | Run in dabterm |
|---|---|---|
| `hello-go` | `cd hello-go && GOOS=wasip1 GOARCH=wasm go build -o hello-go.wasm .` (Go 1.21+) | `wasm hello-go.wasm 50` |
| `hello-cpp` | `cd hello-cpp && $WASI_SDK/bin/clang++ -O2 -std=c++20 -o hello-cpp.wasm main.cpp` ([wasi-sdk](https://github.com/WebAssembly/wasi-sdk)) | `wasm hello-cpp.wasm 10` |

Both read stdin when something is piped: `echo "a b c" | hello-go`, `echo "3 1 2" | hello-cpp`.
