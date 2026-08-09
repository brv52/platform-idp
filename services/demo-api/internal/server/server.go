// Package server wires the demo-api HTTP handlers.
//
// Two listeners are used: the app listener carries user traffic (and is the
// only one that sees injected faults), the ops listener carries /metrics,
// probes and the fault admin API so that scraping and probing keep working
// while the app path is deliberately degraded.
package server

import (
	"encoding/json"
	"log/slog"
	"net/http"
	"os"
	"sync/atomic"
	"time"

	"github.com/brv52/platform-idp/services/demo-api/internal/faults"
)

// Options configures the handlers.
type Options struct {
	Version string
	Faults  *faults.Injector
	Logger  *slog.Logger
	// Middleware wraps the app routes outermost, e.g. tracing and request
	// metrics. Applied in order, so Middleware[0] sees the request first.
	Middleware []func(http.Handler) http.Handler
	// Metrics is served on the ops listener at /metrics when non-nil.
	Metrics http.Handler
	// EnableAdmin exposes /admin/faults on the ops listener.
	EnableAdmin bool
}

// Server holds handler state shared by both listeners.
type Server struct {
	opts     Options
	hostname string
	ready    atomic.Bool
}

// New returns a Server that reports ready immediately.
func New(opts Options) *Server {
	if opts.Logger == nil {
		opts.Logger = slog.Default()
	}
	h, _ := os.Hostname()
	s := &Server{opts: opts, hostname: h}
	s.ready.Store(true)
	return s
}

// SetReady flips the readiness probe; call SetReady(false) at the start of
// graceful shutdown so endpoints are removed before listeners close.
func (s *Server) SetReady(v bool) { s.ready.Store(v) }

// App returns the handler for user traffic. It is also served over mTLS.
func (s *Server) App() http.Handler {
	// Faults wrap each API route individually, after the mux has matched it,
	// so injected errors and latency are recorded under the real route
	// pattern instead of a catch-all prefix.
	mux := http.NewServeMux()
	mux.Handle("GET /api/v1/items", s.withFaults(s.items))
	mux.Handle("GET /api/v1/whoami", s.withFaults(s.whoami))
	mux.HandleFunc("GET /healthz", s.healthz)

	var out http.Handler = mux
	for i := len(s.opts.Middleware) - 1; i >= 0; i-- {
		out = s.opts.Middleware[i](out)
	}
	return out
}

func (s *Server) withFaults(h http.HandlerFunc) http.Handler {
	if s.opts.Faults == nil {
		return h
	}
	return s.opts.Faults.Middleware(h)
}

// Ops returns the handler for probes, metrics and fault administration.
func (s *Server) Ops() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	if s.opts.Metrics != nil {
		mux.Handle("GET /metrics", s.opts.Metrics)
	}
	if s.opts.EnableAdmin && s.opts.Faults != nil {
		mux.Handle("/admin/faults", s.opts.Faults.AdminHandler())
	}
	return mux
}

type item struct {
	ID    int    `json:"id"`
	Name  string `json:"name"`
	Price int    `json:"price_cents"`
}

var catalog = []item{
	{1, "keyboard", 8900}, {2, "mouse", 3400}, {3, "monitor", 21900},
	{4, "headset", 5900}, {5, "dock", 14900},
}

func (s *Server) items(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"version": s.opts.Version,
		"served":  s.hostname,
		"items":   catalog,
	})
}

// whoami reports the caller's SPIFFE ID when the request arrived over mTLS.
func (s *Server) whoami(w http.ResponseWriter, r *http.Request) {
	resp := map[string]any{"version": s.opts.Version, "served": s.hostname}
	if r.TLS != nil && len(r.TLS.PeerCertificates) > 0 {
		leaf := r.TLS.PeerCertificates[0]
		if len(leaf.URIs) > 0 {
			resp["peer_spiffe_id"] = leaf.URIs[0].String()
		}
		resp["peer_cert_expires"] = leaf.NotAfter.UTC().Format(time.RFC3339)
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) readyz(w http.ResponseWriter, _ *http.Request) {
	if !s.ready.Load() {
		writeJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "shutting down"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

func writeJSON(w http.ResponseWriter, code int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}
