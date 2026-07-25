// flotilla-beacon: Proxmox-side companion. Receives PVE webhook notifications on
// 127.0.0.1, seals them (E2E) and forwards to the relay; heartbeats every 60s;
// sends a going-down heartbeat on SIGTERM (clean host shutdown).
package main

import (
	"bufio"
	"bytes"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/Livin21/flotilla-agent/internal/sealbox"
)

type config struct {
	Relay, Pairing, Secret, Listen string
	Key                            []byte
}

func parseConf(r io.Reader) (config, error) {
	cfg := config{Listen: "127.0.0.1:8799"}
	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		switch k {
		case "relay":
			cfg.Relay = v
		case "pairing":
			cfg.Pairing = v
		case "secret":
			cfg.Secret = v
		case "listen":
			cfg.Listen = v
		case "key":
			key, err := base64.RawURLEncoding.DecodeString(v)
			if err != nil || len(key) != 32 {
				return cfg, errors.New("bad key")
			}
			cfg.Key = key
		}
	}
	if err := sc.Err(); err != nil {
		return cfg, err
	}
	if cfg.Relay == "" || cfg.Pairing == "" || cfg.Secret == "" || cfg.Key == nil {
		return cfg, errors.New("incomplete config")
	}
	return cfg, nil
}

// mapSeverity mirrors §P's PVE severity→importance/level table: error→alert/
// time-sensitive, warning→warning/active, everything else (info, notice, ...)
// →normal/passive.
func mapSeverity(sev string) (importance, level string) {
	switch sev {
	case "error":
		return "alert", "time-sensitive"
	case "warning":
		return "warning", "active"
	default:
		return "normal", "passive"
	}
}

// httpClient is shared by every outbound call to the relay. Its 5s timeout is
// what makes the going-down heartbeat sent from the SIGTERM handler bounded —
// a hung or unreachable relay can delay shutdown by at most this long, never
// indefinitely (see beacon/flotilla-beacon.service's TimeoutStopSec, sized
// with headroom above this).
var httpClient = &http.Client{Timeout: 5 * time.Second}

func post(cfg config, path string, body any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequest("POST", cfg.Relay+path, bytes.NewReader(buf))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+cfg.Secret)
	req.Header.Set("Content-Type", "application/json")
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	return nil
}

// authorized reports whether r carries exactly the configured bearer secret,
// compared in constant time. The beacon is meant to listen on loopback only,
// but the comparison is hardened anyway: it's cheap, and it removes any
// timing signal a misconfiguration (or a future code change) might otherwise
// expose to whoever can reach the port.
func authorized(r *http.Request, secret string) bool {
	want := []byte("Bearer " + secret)
	got := []byte(r.Header.Get("Authorization"))
	if len(got) != len(want) {
		return false
	}
	return subtle.ConstantTimeCompare(got, want) == 1
}

// maxBodyBytes bounds the webhook body read. PVE's own webhook payloads are a
// few hundred bytes; 64KiB is generous headroom while still ruling out an
// unbounded read from a malicious or misbehaving sender on the loopback port.
const maxBodyBytes = 64 << 10

func handleWebhook(cfg config, w http.ResponseWriter, r *http.Request) {
	if !authorized(r, cfg.Secret) {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	var in struct{ Severity, Title, Message string }
	if err := json.NewDecoder(io.LimitReader(r.Body, maxBodyBytes)).Decode(&in); err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	importance, level := mapSeverity(in.Severity)
	payload, err := json.Marshal(map[string]any{
		"v": 1, "event": "pve " + in.Severity,
		"subject": in.Title, "description": in.Message, "importance": importance,
		"link": "", "ts": time.Now().Unix(),
	})
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	sealed, err := sealbox.Seal(cfg.Key, payload)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	if err := post(cfg, "/v1/push", map[string]string{"pairingID": cfg.Pairing, "sealed": sealed, "level": level}); err != nil {
		log.Printf("forward failed: %v", err)
	}
	w.WriteHeader(http.StatusAccepted)
}

func heartbeat(cfg config, state string) {
	if err := post(cfg, "/v1/heartbeat", map[string]string{"pairingID": cfg.Pairing, "state": state}); err != nil {
		log.Printf("heartbeat failed: %v", err)
	}
}

// isLoopback reports whether addr (a host:port listen address, or a bare
// host) resolves to loopback. Used only to warn — not to refuse to start —
// because an operator who deliberately widens `listen=` (e.g. behind their
// own firewall/VPN) should still be able to.
func isLoopback(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	if host == "" {
		return false
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.IsLoopback()
	}
	return host == "localhost"
}

func heartbeatLoop(cfg config) {
	heartbeat(cfg, "ok")
	for range time.Tick(60 * time.Second) {
		heartbeat(cfg, "ok")
	}
}

// serve runs the webhook listener until sig delivers a shutdown signal, then
// sends a going-down heartbeat and closes the server. It's factored out of
// main so tests can drive shutdown with a synthetic signal channel instead of
// the process's real one.
func serve(cfg config, sig <-chan os.Signal) error {
	if !isLoopback(cfg.Listen) {
		log.Printf("WARNING: listen=%s is not loopback-only; anyone who can reach this port and obtain the bearer secret can inject notifications", cfg.Listen)
	}

	go heartbeatLoop(cfg)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /", func(w http.ResponseWriter, r *http.Request) { handleWebhook(cfg, w, r) })
	srv := &http.Server{Addr: cfg.Listen, Handler: mux}

	go func() {
		<-sig
		// Bounded by httpClient's 5s timeout (see its comment above) — this
		// can never hang shutdown indefinitely, even against an unreachable
		// or hung relay. A second SIGTERM/SIGINT arriving while this is in
		// flight is either queued in the (size-1, buffered) channel or
		// dropped by the runtime if that slot is already full: os/signal
		// never blocks the sender, and this goroutine only ever reads `sig`
		// once, so there is no deadlock risk from a repeated signal.
		heartbeat(cfg, "going-down")
		srv.Close()
	}()

	fmt.Println("flotilla-beacon listening on", cfg.Listen)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		return err
	}
	return nil
}

func main() {
	f, err := os.Open("/etc/flotilla-beacon.conf")
	if err != nil {
		log.Fatal(err)
	}
	cfg, err := parseConf(f)
	f.Close()
	if err != nil {
		log.Fatal(err)
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)

	if err := serve(cfg, sig); err != nil {
		log.Fatal(err)
	}
}
