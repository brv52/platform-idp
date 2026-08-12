package identity

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ProbeConfig drives continuous mTLS traffic against one URL.
type ProbeConfig struct {
	URL         string
	TLS         *tls.Config
	RPS         int
	Concurrency int
	Timeout     time.Duration
}

// ProbeStats is the outcome of a probe run. Every request uses a new
// connection, so Requests is also the number of TLS handshakes attempted.
type ProbeStats struct {
	Requests          int64     `json:"requests"`
	OK                int64     `json:"ok"`
	HandshakeFailures int64     `json:"handshake_failures"`
	HTTPErrors        int64     `json:"http_errors"`
	OtherErrors       int64     `json:"other_errors"`
	ServerSerials     int       `json:"distinct_server_svids"`
	LastError         string    `json:"last_error,omitempty"`
	Started           time.Time `json:"started"`
	Finished          time.Time `json:"finished"`

	serials map[string]struct{}
}

// Failures is every request that did not get a 2xx response.
func (s ProbeStats) Failures() int64 { return s.HandshakeFailures + s.HTTPErrors + s.OtherErrors }

// Probe sends requests at cfg.RPS until ctx is done. onTick, when non-nil,
// receives a snapshot every interval.
func Probe(ctx context.Context, cfg ProbeConfig, interval time.Duration, onTick func(ProbeStats)) ProbeStats {
	if cfg.Concurrency <= 0 {
		cfg.Concurrency = 4
	}
	if cfg.RPS <= 0 {
		cfg.RPS = 10
	}
	if cfg.Timeout <= 0 {
		cfg.Timeout = 5 * time.Second
	}
	client := &http.Client{
		Timeout: cfg.Timeout,
		Transport: &http.Transport{
			TLSClientConfig:   cfg.TLS,
			DisableKeepAlives: true, // one handshake per request
			ForceAttemptHTTP2: false,
		},
	}

	var mu sync.Mutex
	stats := ProbeStats{Started: time.Now(), serials: map[string]struct{}{}}
	record := func(resp *http.Response, err error) {
		mu.Lock()
		defer mu.Unlock()
		stats.Requests++
		switch {
		case err != nil && ctx.Err() != nil:
			stats.Requests-- // cancelled at shutdown, not a failure
		case err != nil && isHandshakeError(err):
			stats.HandshakeFailures++
			stats.LastError = err.Error()
		case err != nil:
			stats.OtherErrors++
			stats.LastError = err.Error()
		case resp.StatusCode/100 != 2:
			stats.HTTPErrors++
			stats.LastError = resp.Status
		default:
			stats.OK++
		}
		if resp != nil && resp.TLS != nil && len(resp.TLS.PeerCertificates) > 0 {
			stats.serials[resp.TLS.PeerCertificates[0].SerialNumber.String()] = struct{}{}
			stats.ServerSerials = len(stats.serials)
		}
	}
	snapshot := func() ProbeStats {
		mu.Lock()
		defer mu.Unlock()
		s := stats
		s.serials = nil
		return s
	}

	jobs := make(chan struct{})
	var wg sync.WaitGroup
	for range cfg.Concurrency {
		wg.Go(func() {
			for range jobs {
				req, _ := http.NewRequestWithContext(ctx, http.MethodGet, cfg.URL, nil)
				resp, err := client.Do(req)
				if resp != nil {
					_, _ = io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
				}
				record(resp, err)
			}
		})
	}

	tick := time.NewTicker(time.Second / time.Duration(cfg.RPS))
	defer tick.Stop()
	var report <-chan time.Time
	if onTick != nil && interval > 0 {
		r := time.NewTicker(interval)
		defer r.Stop()
		report = r.C
	}
loop:
	for {
		select {
		case <-ctx.Done():
			break loop
		case <-report:
			onTick(snapshot())
		case <-tick.C:
			select {
			case jobs <- struct{}{}:
			default: // all workers busy; the shortfall shows up as lower Requests
			}
		}
	}
	close(jobs)
	wg.Wait()
	out := snapshot()
	out.Finished = time.Now()
	return out
}

func isHandshakeError(err error) bool {
	var (
		verr *tls.CertificateVerificationError
		rerr tls.RecordHeaderError
		aerr tls.AlertError
		uerr x509.UnknownAuthorityError
	)
	if errors.As(err, &verr) || errors.As(err, &rerr) || errors.As(err, &aerr) || errors.As(err, &uerr) {
		return true
	}
	// go-spiffe peer verification errors surface as plain errors from the
	// handshake; net/http does not wrap them in a typed error.
	var nerr net.Error
	if errors.As(err, &nerr) && nerr.Timeout() {
		return false
	}
	msg := err.Error()
	return strings.Contains(msg, "tls:") || strings.Contains(msg, "x509svid:") || strings.Contains(msg, "remote error")
}
