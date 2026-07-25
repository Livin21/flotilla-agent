package main

import (
	"bytes"
	"encoding/base64"
	"os"
	"testing"
)

const envVar = "FLOTILLA_SEAL_KEY"

// setArgsAndEnv sets os.Args and FLOTILLA_SEAL_KEY for the duration of the test,
// restoring both on cleanup so tests don't leak global state into each other.
func setArgsAndEnv(t *testing.T, args []string, envKey string) {
	t.Helper()
	origArgs := os.Args
	origEnv, hadEnv := os.LookupEnv(envVar)
	os.Args = args
	if envKey == "" {
		os.Unsetenv(envVar)
	} else {
		os.Setenv(envVar, envKey)
	}
	t.Cleanup(func() {
		os.Args = origArgs
		if hadEnv {
			os.Setenv(envVar, origEnv)
		} else {
			os.Unsetenv(envVar)
		}
	})
}

func mkKey(fill byte) []byte {
	k := make([]byte, 32)
	for i := range k {
		k[i] = fill
	}
	return k
}

func TestKeyArgFromFlag(t *testing.T) {
	key := mkKey(0x01)
	setArgsAndEnv(t, []string{"flotilla-seal", "seal", "--key", base64.RawURLEncoding.EncodeToString(key)}, "")
	got := keyArg()
	if !bytes.Equal(got, key) {
		t.Fatalf("keyArg via --key = %x, want %x", got, key)
	}
}

func TestKeyArgFromEnv(t *testing.T) {
	key := mkKey(0x02)
	// No --key on argv at all: seal command has no flags.
	setArgsAndEnv(t, []string{"flotilla-seal", "seal"}, base64.RawURLEncoding.EncodeToString(key))
	got := keyArg()
	if !bytes.Equal(got, key) {
		t.Fatalf("keyArg via %s env = %x, want %x", envVar, got, key)
	}
}

func TestKeyArgFlagWinsOverEnv(t *testing.T) {
	flagKey := mkKey(0x03)
	envKey := mkKey(0x04)
	setArgsAndEnv(t, []string{"flotilla-seal", "seal", "--key", base64.RawURLEncoding.EncodeToString(flagKey)},
		base64.RawURLEncoding.EncodeToString(envKey))
	got := keyArg()
	if !bytes.Equal(got, flagKey) {
		t.Fatalf("--key must win over %s: keyArg = %x, want %x", envVar, got, flagKey)
	}
}
