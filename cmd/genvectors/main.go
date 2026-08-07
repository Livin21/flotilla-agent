// genvectors writes vectors/vectors.json — the cross-implementation test vectors
// shared with the iOS app (LabKit). Deterministic: fixed keys and nonces.
package main

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"

	"golang.org/x/crypto/chacha20poly1305"
)

type vec struct {
	Name      string `json:"name"`
	KeyB64URL string `json:"key_b64url"`
	NonceB64  string `json:"nonce_b64"`
	Plaintext string `json:"plaintext"`
	SealedB64 string `json:"sealed_b64"`
}

func mk(name string, keyByte, nonceByte byte, plaintext string) vec {
	key := make([]byte, 32)
	for i := range key {
		key[i] = keyByte
	}
	nonce := make([]byte, 12)
	for i := range nonce {
		nonce[i] = nonceByte
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil {
		log.Fatalf("%s: %v", name, err)
	}
	sealed := aead.Seal(nonce, nonce, []byte(plaintext), nil)
	return vec{name, base64.RawURLEncoding.EncodeToString(key),
		base64.StdEncoding.EncodeToString(nonce), plaintext,
		base64.StdEncoding.EncodeToString(sealed)}
}

func main() {
	vs := []vec{
		mk("empty", 0x01, 0x02, ""),
		mk("unicode", 0x42, 0x24, "Tower · disk1 hot — 46 °C ✓"),
		mk("payload", 0xA5, 0x5A, `{"v":1,"event":"Unraid disk temperature","subject":"Warning [TOWER] - disk1 is hot (46 C)","description":"WDC_WD40 (sdb)","importance":"warning","link":"/Main","ts":1753400000}`),
	}
	out, err := json.MarshalIndent(vs, "", "  ")
	if err != nil {
		log.Fatal(err)
	}
	path := outPath()
	if err := os.WriteFile(path, append(out, '\n'), 0644); err != nil {
		log.Fatal(err)
	}
	fmt.Println("wrote", path)
}

// outPath is the destination for the vectors file: an explicit first argument if given,
// otherwise vectors/vectors.json resolved relative to THIS SOURCE FILE rather than to the
// process's working directory. main() used to write the bare relative path
// "vectors/vectors.json" and discard os.WriteFile's error, so running `go run ./cmd/genvectors`
// from anywhere but the repo root either created a stray vectors/ tree somewhere else or
// silently did nothing at all — for the one file that is the cross-implementation contract
// shared with the iOS app, where "silently did nothing" means the vectors quietly stop matching
// the code that is supposed to generate them.
func outPath() string {
	if len(os.Args) > 1 {
		return os.Args[1]
	}
	_, self, _, ok := runtime.Caller(0)
	if !ok {
		log.Fatal("cannot determine this file's path; pass an output path as the first argument")
	}
	return filepath.Join(filepath.Dir(self), "..", "..", "vectors", "vectors.json")
}
