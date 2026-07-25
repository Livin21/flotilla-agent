package sealbox

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

func TestRoundTrip(t *testing.T) {
	key := make([]byte, 32)
	rand.Read(key)
	msg := []byte(`{"v":1,"event":"Unraid disk temperature","subject":"Warning [TOWER] - disk1 is hot (46 C)","description":"WDC_WD40 (sdb)","importance":"warning","link":"/Main","ts":1753400000}`)
	sealed, err := Seal(key, msg)
	if err != nil { t.Fatal(err) }
	got, err := Open(key, sealed)
	if err != nil { t.Fatal(err) }
	if !bytes.Equal(got, msg) { t.Fatalf("roundtrip mismatch") }
}

func TestOpenRejectsTamper(t *testing.T) {
	key := make([]byte, 32)
	rand.Read(key)
	sealed, _ := Seal(key, []byte("hello"))
	raw, _ := base64.StdEncoding.DecodeString(sealed)
	raw[len(raw)-1] ^= 0xFF
	if _, err := Open(key, base64.StdEncoding.EncodeToString(raw)); err == nil {
		t.Fatal("tampered ciphertext must fail")
	}
}

func TestOpenRejectsWrongKey(t *testing.T) {
	k1 := make([]byte, 32); rand.Read(k1)
	k2 := make([]byte, 32); rand.Read(k2)
	sealed, _ := Seal(k1, []byte("hello"))
	if _, err := Open(k2, sealed); err == nil { t.Fatal("wrong key must fail") }
}

func TestSealRejectsBadKeyLen(t *testing.T) {
	if _, err := Seal([]byte("short"), []byte("x")); err == nil { t.Fatal("short key must fail") }
}

func TestVectorsOpen(t *testing.T) {
	data, err := os.ReadFile("../../vectors/vectors.json")
	if err != nil { t.Fatal(err) }
	var vs []struct {
		Name string `json:"name"`; KeyB64URL string `json:"key_b64url"`
		Plaintext string `json:"plaintext"`; SealedB64 string `json:"sealed_b64"`
	}
	if err := json.Unmarshal(data, &vs); err != nil { t.Fatal(err) }
	if len(vs) != 3 { t.Fatalf("want 3 vectors, got %d", len(vs)) }
	for _, v := range vs {
		key, _ := base64.RawURLEncoding.DecodeString(v.KeyB64URL)
		got, err := Open(key, v.SealedB64)
		if err != nil { t.Fatalf("%s: %v", v.Name, err) }
		if string(got) != v.Plaintext { t.Fatalf("%s: plaintext mismatch", v.Name) }
	}
}
