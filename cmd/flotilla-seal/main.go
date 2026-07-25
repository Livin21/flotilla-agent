// flotilla-seal: keygen | seal --key <b64url> | open --key <b64url>. stdin→stdout.
// Key may also come from the FLOTILLA_SEAL_KEY env var when --key is omitted
// (keeps the key off argv/ps); --key takes precedence when both are given.
package main

import (
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"io"
	"os"

	"github.com/Livin21/flotilla-agent/internal/sealbox"
)

func die(msg string) { fmt.Fprintln(os.Stderr, "flotilla-seal: "+msg); os.Exit(1) }

// keyArg resolves the key from --key <b64url> if present (back-compat, and it
// always wins), else from the FLOTILLA_SEAL_KEY env var (keeps the secret off
// argv/ps output for callers like send-event.sh).
func keyArg() []byte {
	var b64 string
	switch {
	case len(os.Args) >= 4 && os.Args[2] == "--key":
		b64 = os.Args[3]
	case os.Getenv("FLOTILLA_SEAL_KEY") != "":
		b64 = os.Getenv("FLOTILLA_SEAL_KEY")
	default:
		die("usage: flotilla-seal seal|open --key <b64url> (or set FLOTILLA_SEAL_KEY env var; --key wins if both given)")
	}
	k, err := base64.RawURLEncoding.DecodeString(b64)
	if err != nil || len(k) != 32 {
		die("key must be 32 bytes base64url")
	}
	return k
}

func main() {
	if len(os.Args) < 2 {
		die("usage: flotilla-seal keygen|seal|open")
	}
	switch os.Args[1] {
	case "keygen":
		k := make([]byte, 32)
		if _, err := rand.Read(k); err != nil {
			die(err.Error())
		}
		fmt.Println(base64.RawURLEncoding.EncodeToString(k))
	case "seal":
		key := keyArg()
		in, _ := io.ReadAll(os.Stdin)
		out, err := sealbox.Seal(key, in)
		if err != nil {
			die(err.Error())
		}
		fmt.Println(out)
	case "open":
		key := keyArg()
		in, _ := io.ReadAll(os.Stdin)
		out, err := sealbox.Open(key, string(trimNL(in)))
		if err != nil {
			die(err.Error())
		}
		os.Stdout.Write(out)
	default:
		die("unknown command " + os.Args[1])
	}
}

func trimNL(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r') {
		b = b[:len(b)-1]
	}
	return b
}
