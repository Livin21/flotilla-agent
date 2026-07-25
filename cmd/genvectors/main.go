// genvectors writes vectors/vectors.json — the cross-implementation test vectors
// shared with the iOS app (LabKit). Deterministic: fixed keys and nonces.
package main

import (
	"encoding/base64"
	"encoding/json"
	"os"

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
	for i := range key { key[i] = keyByte }
	nonce := make([]byte, 12)
	for i := range nonce { nonce[i] = nonceByte }
	aead, _ := chacha20poly1305.New(key)
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
	out, _ := json.MarshalIndent(vs, "", "  ")
	os.WriteFile("vectors/vectors.json", append(out, '\n'), 0644)
}
