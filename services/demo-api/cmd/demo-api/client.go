package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"sync/atomic"
	"time"

	"github.com/brv52/platform-idp/services/demo-api/internal/identity"
)

// client generates continuous mTLS traffic and prints a JSON summary on
// exit. bench/svid-rotation.sh runs it across several SVID rotations and
// fails the run on any non-zero failure count.
func client(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("client", flag.ContinueOnError)
	target := fs.String("target", envOr("MTLS_TARGET", "https://demo-api-mtls:8443/api/v1/whoami"), "URL to call")
	serverID := fs.String("server-id", os.Getenv("MTLS_SERVER_ID"), "expected server SPIFFE ID(s) or trust domain (default: own trust domain)")
	rps := fs.Int("rps", 20, "requests (and therefore handshakes) per second")
	conc := fs.Int("concurrency", 4, "parallel workers")
	duration := fs.Duration("duration", 0, "stop after this long (0 = until SIGTERM)")
	report := fs.Duration("report-interval", 30*time.Second, "progress log period")
	socket := fs.String("spiffe-socket", "", "Workload API socket (default: $SPIFFE_ENDPOINT_SOCKET)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	src, err := waitForSource(ctx, *socket)
	if err != nil {
		return err
	}
	defer src.Close()
	id, err := identity.LocalID(src)
	if err != nil {
		return err
	}
	authz, err := identity.ParseAuthorizer(*serverID, id.TrustDomain())
	if err != nil {
		return err
	}

	if *duration > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, *duration)
		defer cancel()
	}

	var rotations atomic.Int64
	go identity.WatchRotations(ctx, src, src.Updated(), func(r identity.Rotation) {
		rotations.Add(1)
		logRotation(r)
	})

	slog.Info("probing", "id", id.String(), "target", *target, "rps", *rps, "duration", duration.String())
	stats := identity.Probe(ctx, identity.ProbeConfig{
		URL:         *target,
		TLS:         identity.ClientConfig(src, authz),
		RPS:         *rps,
		Concurrency: *conc,
	}, *report, func(s identity.ProbeStats) {
		slog.Info("progress", "requests", s.Requests, "ok", s.OK, "failures", s.Failures(),
			"handshake_failures", s.HandshakeFailures, "server_svids", s.ServerSerials, "client_rotations", rotations.Load())
	})

	out := struct {
		identity.ProbeStats
		ClientID        string  `json:"client_id"`
		Target          string  `json:"target"`
		ClientRotations int64   `json:"client_rotations"`
		DurationSeconds float64 `json:"duration_seconds"`
	}{stats, id.String(), *target, rotations.Load(), stats.Finished.Sub(stats.Started).Seconds()}
	enc := json.NewEncoder(os.Stdout)
	enc.SetIndent("", "  ")
	if err := enc.Encode(out); err != nil {
		return err
	}
	if stats.Failures() > 0 {
		return fmt.Errorf("%d failed requests (%d handshake failures)", stats.Failures(), stats.HandshakeFailures)
	}
	return nil
}
