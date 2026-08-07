// flotilla-beacon: Proxmox-side companion. Receives PVE webhook notifications on
// 127.0.0.1, seals them (E2E) and forwards to the relay; heartbeats every 60s;
// sends a going-down heartbeat on SIGTERM (clean host shutdown).
package main

import (
	"bufio"
	"bytes"
	"context"
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
	"sync"
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

// httpClient is shared by every outbound call to the relay, including the
// periodic "ok" heartbeat: its 5s timeout is what bounds an "ok" call that
// isn't pre-empted for some other reason. The going-down heartbeat instead
// uses its own shorter goingDownTimeout via a per-request context (see
// heartbeatSender), so a hung or unreachable relay can never delay shutdown
// by more than that, regardless of what else this client's Timeout is set
// to (see beacon/flotilla-beacon.service's TimeoutStopSec, sized with
// headroom above the sum of both).
var httpClient = &http.Client{Timeout: 5 * time.Second}

func post(cfg config, path string, body any) error {
	return postCtx(context.Background(), cfg, path, body)
}

// postCtx is post with an explicit, cancellable context — used by
// heartbeatSender so an in-flight periodic "ok" can be preempted rather than
// waited out (see heartbeatSender's doc comment).
func postCtx(ctx context.Context, cfg config, path string, body any) error {
	buf, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, "POST", cfg.Relay+path, bytes.NewReader(buf))
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
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		// Distinct from a network-level failure (caller logs this the same
		// way, but the message makes clear the relay was reached and didn't
		// like the request) — a misconfigured secret (401), a capped pairing
		// (429), or a relay-side error (5xx) would otherwise be silently
		// swallowed. Never include cfg.Secret here: path and status are all
		// an operator needs.
		return fmt.Errorf("relay %s: unexpected status %d", path, resp.StatusCode)
	}
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
		// I4: log it. A PVE webhook target configured without the Authorization header (or
		// with a stale one, e.g. after a re-pair that rotated S) used to fail completely
		// silently: PVE records a delivery failure the operator never looks at, the beacon
		// wrote nothing at all, and the phone simply never buzzed while heartbeats kept the
		// server showing as online and healthy. One line in `journalctl -u flotilla-beacon`
		// makes that diagnosable. The secret is never logged; whether a header was present
		// at all is the only thing that distinguishes the two realistic misconfigurations.
		log.Printf("rejected unauthorized webhook from %s (Authorization header %s) — check the "+
			"PVE notification target's header against /etc/flotilla-beacon.conf",
			r.RemoteAddr, map[bool]string{true: "present but wrong", false: "missing"}[r.Header.Get("Authorization") != ""])
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
	heartbeatCtx(context.Background(), cfg, state)
}

// heartbeatCtx is heartbeat with an explicit context, so a caller can bound
// or cancel the underlying request without waiting on httpClient's full 5s
// timeout.
func heartbeatCtx(ctx context.Context, cfg config, state string) {
	if err := postCtx(ctx, cfg, "/v1/heartbeat", map[string]string{"pairingID": cfg.Pairing, "state": state}); err != nil {
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

// goingDownTimeout bounds going-down's own network attempt. It's
// deliberately shorter than httpClient's shared 5s timeout: going-down is
// the last thing shutdown does, so it gets a tight, dedicated budget rather
// than the generic per-request timeout every other call uses. See
// heartbeatSender's doc comment for how this fits into the overall shutdown
// budget, and beacon/flotilla-beacon.service's TimeoutStopSec comment for
// the systemd-level margin above it.
const goingDownTimeout = 3 * time.Second

// heartbeatSender makes the "going-down" heartbeat provably the last one the
// relay can see for a given shutdown, and bounds how long that takes even
// when a periodic "ok" is mid-flight against a hanging relay.
//
// Without any coordination, the periodic 60s "ok" heartbeat runs on its own
// uncoordinated goroutine, and a tick landing at (or just after) the moment
// SIGTERM fires can race the going-down send — the relay then sees
// "going-down" followed by "ok", re-arms its 180s dead-man alarm (any
// non-"going-down" state does that, per §P), and can later page a false
// "server unreachable" for what was actually a clean, planned reboot.
//
// An earlier version fixed the race by serializing every send behind a
// mutex held across the network call: going-down would block on that mutex
// until an in-flight "ok" released it naturally. That closed the ordering
// hole but reopened a latency one — an "ok" in flight against a hanging
// relay would run out its own full httpClient timeout before going-down's
// call could even start, compounding two timeouts back-to-back (measured
// ~10s against a 10s systemd TimeoutStopSec: SIGKILL territory).
//
// This version fixes it by preemption instead of waiting: send()
//   - sets stopped = true before doing anything else, so no *new* "ok" can
//     start once shutdown has begun (a send("ok") that loses the race for mu
//     sees stopped and returns without ever touching the network);
//   - cancels the context of an "ok" already in flight, so it aborts almost
//     immediately instead of running to its natural timeout, and *waits* for
//     that abort to actually land (h.inFlightDone) before proceeding — this
//     keeps the strict ordering guarantee (going-down's request is never
//     dispatched while an "ok" from the same sender could still be in transit)
//     but bounds the wait to "however long a cancelled request takes to
//     unwind" (milliseconds) rather than "however long the relay takes to
//     respond, or 5s, whichever is later";
//   - then sends going-down with its own short, independent budget
//     (goingDownTimeout), so even a relay that never responds at all can't
//     hold shutdown hostage for longer than that.
//
// The mutex itself is only ever held for bookkeeping (reading/writing
// stopped, cancel, inFlightDone) — never across a network call — which is
// what makes the preemption possible: the old design deadlocked shutdown's
// *ability to cancel* behind the very call it needed to cancel.
type heartbeatSender struct {
	cfg config

	mu           sync.Mutex
	stopped      bool
	cancel       context.CancelFunc // cancels the "ok" request currently in flight, if any
	inFlightDone chan struct{}      // closed when that request's heartbeatCtx call returns
}

func newHeartbeatSender(cfg config) *heartbeatSender { return &heartbeatSender{cfg: cfg} }

func (h *heartbeatSender) send(state string) {
	if state == "going-down" {
		h.sendGoingDown()
		return
	}
	h.sendOK(state)
}

// sendOK sends a non-going-down (periodic "ok") heartbeat, recording a
// cancel func and completion signal that a concurrent going-down can use to
// preempt it. Never called with state == "going-down".
func (h *heartbeatSender) sendOK(state string) {
	h.mu.Lock()
	if h.stopped {
		h.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	h.cancel = cancel
	h.inFlightDone = done
	h.mu.Unlock()

	heartbeatCtx(ctx, h.cfg, state)
	close(done)
	cancel() // release ctx's resources; no-op if already cancelled by shutdown

	h.mu.Lock()
	if h.inFlightDone == done { // still the one we set — nothing newer to preserve
		h.cancel = nil
		h.inFlightDone = nil
	}
	h.mu.Unlock()
}

// sendGoingDown is idempotent (a second SIGTERM/SIGINT is a no-op here) and
// is the only path that ever sets stopped = true.
func (h *heartbeatSender) sendGoingDown() {
	h.mu.Lock()
	if h.stopped {
		h.mu.Unlock()
		return
	}
	h.stopped = true
	cancel := h.cancel
	done := h.inFlightDone
	h.mu.Unlock()

	if cancel != nil {
		cancel()
		if done != nil {
			<-done // bounded: a cancelled request unwinds in milliseconds, not httpClient's full timeout
		}
	}

	ctx, cancelDown := context.WithTimeout(context.Background(), goingDownTimeout)
	defer cancelDown()
	heartbeatCtx(ctx, h.cfg, "going-down")
}

// heartbeatLoop sends an immediate "ok" then one every interval, until done
// is closed. Stopping the ticker on done keeps the loop from scheduling any
// *future* "ok" ticks once shutdown begins; the heartbeatSender's mutex+
// stopped guard (not this alone — a tick already selected concurrently with
// done closing is a real race Go's select doesn't resolve in our favor) is
// what actually guarantees going-down is last.
func heartbeatLoop(h *heartbeatSender, interval time.Duration, done <-chan struct{}) {
	h.send("ok")
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			h.send("ok")
		case <-done:
			return
		}
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

	h := newHeartbeatSender(cfg)
	done := make(chan struct{})
	go heartbeatLoop(h, 60*time.Second, done)

	mux := http.NewServeMux()
	mux.HandleFunc("POST /", func(w http.ResponseWriter, r *http.Request) { handleWebhook(cfg, w, r) })
	// I13: explicit timeouts. Without them a client that opens a connection and dribbles
	// headers (or never sends any) holds a goroutine and an fd indefinitely. The default
	// listen is loopback-only so the practical exposure is small, but isLoopback above
	// deliberately *permits* a widened listen= with only a warning — which is exactly the
	// configuration where an unbounded read matters. PVE's webhook payloads are a few
	// hundred bytes delivered locally, so these are generous.
	srv := &http.Server{
		Addr:              cfg.Listen,
		Handler:           mux,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}

	go func() {
		<-sig
		// Stop scheduling future "ok" ticks before sending going-down. This
		// alone doesn't guarantee ordering (a tick already racing done in
		// heartbeatLoop's select could still fire "ok" after this point) —
		// h.send's mutex+stopped guard is what actually makes going-down
		// provably last; see heartbeatSender's doc comment.
		close(done)
		// Bounded by heartbeatSender's preemption logic (see its doc
		// comment): any in-flight "ok" is cancelled rather than waited out,
		// and going-down's own call has its own goingDownTimeout budget — so
		// this can never hang shutdown indefinitely, even against an
		// unreachable or hung relay, and never compounds two full timeouts
		// back-to-back. A second SIGTERM/SIGINT arriving while this is in
		// flight is either queued in the (size-1, buffered) channel or
		// dropped by the runtime if that slot is already full: os/signal
		// never blocks the sender, and this goroutine only ever reads `sig`
		// once, so there is no deadlock risk from a repeated signal.
		h.send("going-down")
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
