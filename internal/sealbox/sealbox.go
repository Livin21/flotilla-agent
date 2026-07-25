// Package sealbox implements Flotilla Push's E2E payload sealing:
// ChaCha20-Poly1305 (IETF), sealed = base64std(nonce12 || ciphertext || tag16).
package sealbox

import (
	"crypto/rand"
	"encoding/base64"
	"errors"

	"golang.org/x/crypto/chacha20poly1305"
)

func Seal(key, plaintext []byte) (string, error) {
	aead, err := chacha20poly1305.New(key)
	if err != nil { return "", err }
	nonce := make([]byte, chacha20poly1305.NonceSize)
	if _, err := rand.Read(nonce); err != nil { return "", err }
	out := aead.Seal(nonce, nonce, plaintext, nil)
	return base64.StdEncoding.EncodeToString(out), nil
}

func Open(key []byte, sealed string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil { return nil, err }
	if len(raw) < chacha20poly1305.NonceSize+chacha20poly1305.Overhead {
		return nil, errors.New("sealed too short")
	}
	aead, err := chacha20poly1305.New(key)
	if err != nil { return nil, err }
	return aead.Open(nil, raw[:chacha20poly1305.NonceSize], raw[chacha20poly1305.NonceSize:], nil)
}
