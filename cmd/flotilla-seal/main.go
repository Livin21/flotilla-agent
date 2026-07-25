// flotilla-seal: keygen | seal --key <b64url> | open --key <b64url>. stdin→stdout.
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

func keyArg() []byte {
	if len(os.Args) < 4 || os.Args[2] != "--key" { die("usage: flotilla-seal seal|open --key <b64url>") }
	k, err := base64.RawURLEncoding.DecodeString(os.Args[3])
	if err != nil || len(k) != 32 { die("key must be 32 bytes base64url") }
	return k
}

func main() {
	if len(os.Args) < 2 { die("usage: flotilla-seal keygen|seal|open") }
	switch os.Args[1] {
	case "keygen":
		k := make([]byte, 32)
		if _, err := rand.Read(k); err != nil { die(err.Error()) }
		fmt.Println(base64.RawURLEncoding.EncodeToString(k))
	case "seal":
		key := keyArg()
		in, _ := io.ReadAll(os.Stdin)
		out, err := sealbox.Seal(key, in)
		if err != nil { die(err.Error()) }
		fmt.Println(out)
	case "open":
		key := keyArg()
		in, _ := io.ReadAll(os.Stdin)
		out, err := sealbox.Open(key, string(trimNL(in)))
		if err != nil { die(err.Error()) }
		os.Stdout.Write(out)
	default:
		die("unknown command " + os.Args[1])
	}
}

func trimNL(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r') { b = b[:len(b)-1] }
	return b
}
