package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/Livin21/flotilla-agent/internal/sealbox"
)

func testCfg(relay string) config {
	key := bytes.Repeat([]byte{0x11}, 32)
	return config{Relay: relay, Pairing: "11111111-1111-4111-8111-111111111111",
		Secret: "c2VjcmV0LXNlY3JldC1zZWNyZXQtc2VjcmV0LXNlY3JldA", Key: key}
}

func TestWebhookSealsAndForwards(t *testing.T) {
	var got struct{ path, auth, body string }
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b := new(bytes.Buffer)
		b.ReadFrom(r.Body)
		got.path, got.auth, got.body = r.URL.Path, r.Header.Get("Authorization"), b.String()
		w.WriteHeader(202)
	}))
	defer relay.Close()
	cfg := testCfg(relay.URL)
	req := httptest.NewRequest("POST", "/", strings.NewReader(`{"severity":"error","title":"Backup failed","message":"vzdump 101"}`))
	req.Header.Set("Authorization", "Bearer "+cfg.Secret)
	w := httptest.NewRecorder()
	handleWebhook(cfg, w, req)
	if w.Code != 202 {
		t.Fatalf("status %d", w.Code)
	}
	if got.path != "/v1/push" {
		t.Fatalf("path %s", got.path)
	}
	if got.auth != "Bearer "+cfg.Secret {
		t.Fatalf("auth %s", got.auth)
	}
	var body struct{ PairingID, Sealed, Level string }
	json.Unmarshal([]byte(got.body), &body)
	if body.Level != "time-sensitive" {
		t.Fatalf("level %s", body.Level)
	}
	plain, err := sealbox.Open(cfg.Key, body.Sealed)
	if err != nil {
		t.Fatal(err)
	}
	var p struct {
		V                                       int
		Event, Subject, Description, Importance string
	}
	json.Unmarshal(plain, &p)
	if p.Subject != "Backup failed" || p.Importance != "alert" || p.V != 1 {
		t.Fatalf("payload %s", plain)
	}
}

func TestWebhookRejectsBadAuth(t *testing.T) {
	cfg := testCfg("http://127.0.0.1:1")
	req := httptest.NewRequest("POST", "/", strings.NewReader(`{}`))
	req.Header.Set("Authorization", "Bearer wrong")
	w := httptest.NewRecorder()
	handleWebhook(cfg, w, req)
	if w.Code != 401 {
		t.Fatalf("status %d", w.Code)
	}
}

func TestSeverityMapping(t *testing.T) {
	for sev, want := range map[string][2]string{
		"info": {"normal", "passive"}, "notice": {"normal", "passive"},
		"warning": {"warning", "active"}, "error": {"alert", "time-sensitive"}} {
		imp, lvl := mapSeverity(sev)
		if imp != want[0] || lvl != want[1] {
			t.Fatalf("%s → %s/%s", sev, imp, lvl)
		}
	}
}

func TestParseConf(t *testing.T) {
	cfg, err := parseConf(strings.NewReader("relay=https://r\npairing=p\nsecret=s\nkey=" +
		base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{0x11}, 32)) + "\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Relay != "https://r" || cfg.Listen != "127.0.0.1:8799" {
		t.Fatalf("%+v", cfg)
	}
}

// ---- Additional tests for the judgment calls the brief left thin ----

// A wrong or missing Authorization header must 401 without ever contacting
// the relay — verified here by failing the test if the relay handler runs at
// all, not just by pointing at an address that happens to be unreachable.
func TestWebhookAuthFailureHasNoSideEffects(t *testing.T) {
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("relay must not be contacted when auth fails, got request to %s", r.URL.Path)
		w.WriteHeader(202)
	}))
	defer relay.Close()
	cfg := testCfg(relay.URL)

	cases := []struct {
		name   string
		header string
		set    bool
	}{
		{"wrong bearer", "Bearer wrong", true},
		{"missing header", "", false},
		{"empty bearer", "Bearer ", true},
		{"secret as prefix of a longer header", "Bearer " + cfg.Secret + "x", true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			req := httptest.NewRequest("POST", "/", strings.NewReader(`{"severity":"error","title":"x","message":"y"}`))
			if c.set {
				req.Header.Set("Authorization", c.header)
			}
			w := httptest.NewRecorder()
			handleWebhook(cfg, w, req)
			if w.Code != http.StatusUnauthorized {
				t.Fatalf("status %d, want 401", w.Code)
			}
		})
	}
}

// The correct secret must still be accepted (paired with the no-side-effect
// cases above, this pins down the exact boundary of the auth comparison).
func TestWebhookAcceptsExactSecret(t *testing.T) {
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(202) }))
	defer relay.Close()
	cfg := testCfg(relay.URL)
	req := httptest.NewRequest("POST", "/", strings.NewReader(`{"severity":"info","title":"x","message":"y"}`))
	req.Header.Set("Authorization", "Bearer "+cfg.Secret)
	w := httptest.NewRecorder()
	handleWebhook(cfg, w, req)
	if w.Code != http.StatusAccepted {
		t.Fatalf("status %d, want 202", w.Code)
	}
}

// A malformed body must 400, never panic the daemon.
func TestWebhookMalformedBodyReturns400NoPanic(t *testing.T) {
	cfg := testCfg("http://127.0.0.1:1")
	req := httptest.NewRequest("POST", "/", strings.NewReader("not json{{{"))
	req.Header.Set("Authorization", "Bearer "+cfg.Secret)
	w := httptest.NewRecorder()
	handleWebhook(cfg, w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400", w.Code)
	}
}

// An empty body is well-formed JSON-absence, not malformed JSON — must not panic either.
func TestWebhookEmptyBodyReturns400NoPanic(t *testing.T) {
	cfg := testCfg("http://127.0.0.1:1")
	req := httptest.NewRequest("POST", "/", strings.NewReader(""))
	req.Header.Set("Authorization", "Bearer "+cfg.Secret)
	w := httptest.NewRecorder()
	handleWebhook(cfg, w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400", w.Code)
	}
}

// The body reader must be bounded: a body far larger than the limit must not
// be decoded whole (no unbounded memory growth) and must fail cleanly.
func TestWebhookBodyOverLimitRejected(t *testing.T) {
	cfg := testCfg("http://127.0.0.1:1")
	huge := `{"severity":"error","title":"` + strings.Repeat("A", 100<<10) + `","message":"y"}`
	req := httptest.NewRequest("POST", "/", strings.NewReader(huge))
	req.Header.Set("Authorization", "Bearer "+cfg.Secret)
	w := httptest.NewRecorder()
	handleWebhook(cfg, w, req)
	if w.Code != http.StatusBadRequest {
		t.Fatalf("status %d, want 400 (truncated by the body limit)", w.Code)
	}
}

func TestIsLoopback(t *testing.T) {
	cases := map[string]bool{
		"127.0.0.1:8799":   true,
		"localhost:8799":   true,
		"[::1]:8799":       true,
		"0.0.0.0:8799":     false,
		"192.168.1.5:8799": false,
		"":                 false,
	}
	for addr, want := range cases {
		if got := isLoopback(addr); got != want {
			t.Errorf("isLoopback(%q) = %v, want %v", addr, got, want)
		}
	}
}

// The going-down heartbeat must be bounded even if the relay never responds
// — this is what stops SIGTERM handling from hanging shutdown indefinitely.
func TestGoingDownHeartbeatBoundedWhenRelayHangs(t *testing.T) {
	block := make(chan struct{})
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-block
	}))
	defer func() { close(block); relay.Close() }()
	cfg := testCfg(relay.URL)

	start := time.Now()
	heartbeat(cfg, "going-down")
	elapsed := time.Since(start)
	if elapsed > 8*time.Second {
		t.Fatalf("heartbeat took %v against a hanging relay, want bounded (~5s client timeout)", elapsed)
	}
	if elapsed < 3*time.Second {
		t.Fatalf("heartbeat returned in %v — suspiciously fast, is the timeout actually wired up?", elapsed)
	}
}

// End-to-end: sending SIGTERM must deliver a going-down heartbeat and then
// shut the server down promptly (not hang, not panic).
func TestSIGTERMSendsGoingDownThenShutsDown(t *testing.T) {
	// Buffered generously: serve() also starts the periodic heartbeat loop,
	// which fires its own "ok" heartbeat on startup — that's a real request
	// that will land here too, before the SIGTERM-triggered one. The
	// assertion below drains until it actually sees "going-down" rather than
	// assuming the first heartbeat received is the one we're testing.
	gotState := make(chan string, 8)
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ PairingID, State string }
		json.NewDecoder(r.Body).Decode(&body)
		w.WriteHeader(200)
		gotState <- body.State
	}))
	defer relay.Close()
	cfg := testCfg(relay.URL)
	cfg.Listen = "127.0.0.1:0"

	sig := make(chan os.Signal, 1)
	errCh := make(chan error, 1)
	go func() { errCh <- serve(cfg, sig) }()
	time.Sleep(100 * time.Millisecond) // let ListenAndServe bind before we signal

	sig <- syscall.SIGTERM

	deadline := time.After(3 * time.Second)
	sawGoingDown := false
	for !sawGoingDown {
		select {
		case s := <-gotState:
			if s == "going-down" {
				sawGoingDown = true
			}
		case <-deadline:
			t.Fatal("going-down heartbeat never reached the relay")
		}
	}
	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("serve returned error: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("serve did not shut down after SIGTERM")
	}
}

// post() must surface a non-2xx relay response as an error distinct from a
// network-level failure (F4): a wrong secret (401), a capped pairing (429),
// or a relay-side error (500) currently gives the operator zero signal
// beyond "it didn't error," which is indistinguishable from success in the
// logs. The error must name the endpoint and status, and must never include
// the secret.
func TestPostReturnsErrorOnNonSuccessStatus(t *testing.T) {
	for _, status := range []int{401, 429, 500} {
		t.Run(fmt.Sprint(status), func(t *testing.T) {
			relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(status)
			}))
			defer relay.Close()
			cfg := testCfg(relay.URL)
			err := post(cfg, "/v1/heartbeat", map[string]string{"pairingID": cfg.Pairing, "state": "ok"})
			if err == nil {
				t.Fatalf("status %d: want error, got nil", status)
			}
			if !strings.Contains(err.Error(), fmt.Sprint(status)) {
				t.Fatalf("error %q doesn't mention status %d", err.Error(), status)
			}
			if !strings.Contains(err.Error(), "/v1/heartbeat") {
				t.Fatalf("error %q doesn't name the endpoint", err.Error())
			}
			if strings.Contains(err.Error(), cfg.Secret) {
				t.Fatalf("error %q leaks the secret", err.Error())
			}
		})
	}
}

// A 2xx relay response must still report no error (guards against an
// overly-broad status check swallowing legitimate success responses like
// 200 or 202).
func TestPostSucceedsOn2xx(t *testing.T) {
	for _, status := range []int{200, 202} {
		relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(status)
		}))
		cfg := testCfg(relay.URL)
		err := post(cfg, "/v1/heartbeat", map[string]string{"pairingID": cfg.Pairing, "state": "ok"})
		relay.Close()
		if err != nil {
			t.Fatalf("status %d: unexpected error %v", status, err)
		}
	}
}

// The webhook's own response to its PVE caller must not change based on
// whatever the relay thought of the forwarded push (F4's explicit
// requirement: a 202 to PVE must not become a failure just because the
// relay is unhappy — e.g. misconfigured secret, capped pairing).
func TestWebhookStillReturns202WhenRelayRejects(t *testing.T) {
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(401)
	}))
	defer relay.Close()
	cfg := testCfg(relay.URL)
	req := httptest.NewRequest("POST", "/", strings.NewReader(`{"severity":"error","title":"x","message":"y"}`))
	req.Header.Set("Authorization", "Bearer "+cfg.Secret)
	w := httptest.NewRecorder()
	handleWebhook(cfg, w, req)
	if w.Code != http.StatusAccepted {
		t.Fatalf("status %d, want 202 regardless of the relay's response", w.Code)
	}
}

// ---- F1: going-down must be provably the last heartbeat ----

// Drives heartbeatLoop with a very short interval so ticks are racing the
// shutdown sequence constantly, then triggers the same close(done);
// h.send("going-down") sequence serve()'s SIGTERM goroutine uses, and
// asserts the LAST request the relay ever saw is going-down. Repeated many
// times (and always run under -race) so a regression — e.g. reverting to
// two independent, unsynchronized heartbeat calls — would reliably be
// caught rather than passing by luck of scheduling.
func TestGoingDownIsProvablyLastHeartbeat(t *testing.T) {
	const iterations = 200
	for i := 0; i < iterations; i++ {
		var mu sync.Mutex
		var states []string
		relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var body struct{ PairingID, State string }
			json.NewDecoder(r.Body).Decode(&body)
			mu.Lock()
			states = append(states, body.State)
			mu.Unlock()
			w.WriteHeader(200)
		}))
		cfg := testCfg(relay.URL)

		h := newHeartbeatSender(cfg)
		done := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			defer wg.Done()
			heartbeatLoop(h, time.Millisecond, done)
		}()

		// Let a handful of "ok" ticks race the shutdown sequence below.
		time.Sleep(3 * time.Millisecond)

		close(done)
		h.send("going-down")
		wg.Wait() // loop goroutine has exited; no further sends can occur.
		relay.Close()

		mu.Lock()
		got := append([]string(nil), states...)
		mu.Unlock()

		if len(got) == 0 {
			t.Fatalf("iteration %d: relay saw no heartbeats at all", i)
		}
		if got[len(got)-1] != "going-down" {
			t.Fatalf("iteration %d: last heartbeat = %q (all: %v), want going-down last", i, got[len(got)-1], got)
		}
		// going-down must appear exactly once — never suppressed, never
		// duplicated by a racing "ok" that slipped past the mutex.
		count := 0
		for _, s := range got {
			if s == "going-down" {
				count++
			}
		}
		if count != 1 {
			t.Fatalf("iteration %d: going-down appeared %d times (all: %v), want exactly 1", i, count, got)
		}
	}
}

// A second signal arriving before/while the first is being handled must not
// deadlock serve() or the OS signal delivery mechanism (which never blocks
// sending into a buffered channel — see the comment in serve()).
func TestSecondSignalDoesNotBlockShutdown(t *testing.T) {
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(200) }))
	defer relay.Close()
	cfg := testCfg(relay.URL)
	cfg.Listen = "127.0.0.1:0"

	sig := make(chan os.Signal, 1)
	sig <- syscall.SIGTERM
	select { // mimic a second signal arriving before serve's goroutine reads the first
	case sig <- syscall.SIGTERM:
	default:
	}

	errCh := make(chan error, 1)
	go func() { errCh <- serve(cfg, sig) }()
	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("serve error: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("serve did not shut down promptly with a signal already queued")
	}
}

// The compound case a code review caught: a periodic "ok" heartbeat is
// in flight (blocked against a relay that never responds) at the exact
// moment SIGTERM arrives. Serializing sends behind a mutex held across the
// network call (the original F1 fix) meant going-down had to wait out the
// "ok" call's *entire* natural timeout before going-down's own call could
// even start — two timeouts back-to-back, ~10s measured in practice,
// against a TimeoutStopSec of only 10s (SIGKILL territory, reintroducing
// the false "server unreachable" push going-down exists to prevent).
//
// This drives the real shutdown routine (serve, not the sender in
// isolation) against a relay whose handler blocks forever on every request,
// so the periodic loop's immediate startup "ok" is still in flight when
// SIGTERM fires. It asserts two things: the relay did see an attempted
// going-down request (proves the preemption didn't just skip sending it),
// and total shutdown time stays well under systemd's timeout (proves the
// in-flight "ok" was pre-empted rather than waited out).
func TestSIGTERMCompoundShutdownBoundedWithOKInFlightAgainstHangingRelay(t *testing.T) {
	gotGoingDown := make(chan struct{}, 1)
	block := make(chan struct{}) // never closed until teardown: every request to this relay hangs forever
	relay := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct{ PairingID, State string }
		json.NewDecoder(r.Body).Decode(&body)
		if body.State == "going-down" {
			select {
			case gotGoingDown <- struct{}{}:
			default:
			}
		}
		<-block // simulates a hung/unreachable relay: never responds to anything
	}))
	defer func() { close(block); relay.Close() }()
	cfg := testCfg(relay.URL)
	cfg.Listen = "127.0.0.1:0"

	sig := make(chan os.Signal, 1)
	errCh := make(chan error, 1)
	go func() { errCh <- serve(cfg, sig) }()
	// Let ListenAndServe bind and heartbeatLoop's immediate startup "ok"
	// actually reach the relay and block in its handler, so it's genuinely
	// in flight (not just scheduled) when SIGTERM fires below.
	time.Sleep(150 * time.Millisecond)

	start := time.Now()
	sig <- syscall.SIGTERM

	select {
	case err := <-errCh:
		elapsed := time.Since(start)
		if err != nil {
			t.Fatalf("serve returned error: %v", err)
		}
		// goingDownTimeout (3s) plus scheduling slack — nowhere near the old
		// compounded ~10s, and well under systemd's TimeoutStopSec (15s).
		if elapsed > 5*time.Second {
			t.Fatalf("compound shutdown took %v, want well under systemd's timeout (in-flight \"ok\" should be pre-empted, not waited out)", elapsed)
		}
	case <-time.After(8 * time.Second):
		t.Fatal("serve did not shut down within the compound-shutdown bound")
	}

	select {
	case <-gotGoingDown:
	default:
		t.Fatal("relay never saw a going-down heartbeat attempt")
	}
}
