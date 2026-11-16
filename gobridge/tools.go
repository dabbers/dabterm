//go:build tools

package yaegi

// Keeps golang.org/x/mobile in go.mod: gomobile bind needs its bind package, and go mod tidy
// would drop it otherwise.
import _ "golang.org/x/mobile/bind"
