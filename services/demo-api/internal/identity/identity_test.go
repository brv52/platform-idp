package identity

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"math/big"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/spiffe/go-spiffe/v2/bundle/x509bundle"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
)

// testCA issues short-lived SVIDs for one trust domain.
type testCA struct {
	td     spiffeid.TrustDomain
	cert   *x509.Certificate
	key    *ecdsa.PrivateKey
	serial atomic.Int64
}

func newTestCA(t *testing.T, td string) *testCA {
	t.Helper()
	ca := &testCA{td: spiffeid.RequireTrustDomainFromString(td)}
	ca.key, _ = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{Organization: []string{"test"}, CommonName: td},
		URIs:                  []*url.URL{ca.td.ID().URL()},
		NotBefore:             time.Now().Add(-time.Minute),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign | x509.KeyUsageCRLSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &ca.key.PublicKey, ca.key)
	if err != nil {
		t.Fatal(err)
	}
	ca.cert, _ = x509.ParseCertificate(der)
	ca.serial.Store(100)
	return ca
}

func (ca *testCA) issue(t *testing.T, path string) *x509svid.SVID {
	t.Helper()
	id := spiffeid.RequireFromPath(ca.td, path)
	key, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(ca.serial.Add(1)),
		URIs:         []*url.URL{id.URL()},
		NotBefore:    time.Now().Add(-time.Minute),
		NotAfter:     time.Now().Add(5 * time.Minute),
		KeyUsage:     x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment | x509.KeyUsageKeyAgreement,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth, x509.ExtKeyUsageClientAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, ca.cert, &key.PublicKey, ca.key)
	if err != nil {
		t.Fatal(err)
	}
	leaf, _ := x509.ParseCertificate(der)
	return &x509svid.SVID{ID: id, Certificates: []*x509.Certificate{leaf}, PrivateKey: key}
}

// rotatingSource mimics workloadapi.X509Source: the current SVID can be
// swapped at any time and an update notification is sent.
type rotatingSource struct {
	mu      sync.RWMutex
	svid    *x509svid.SVID
	bundle  *x509bundle.Bundle
	updated chan struct{}
}

func newRotatingSource(ca *testCA, svid *x509svid.SVID) *rotatingSource {
	return &rotatingSource{
		svid:    svid,
		bundle:  x509bundle.FromX509Authorities(ca.td, []*x509.Certificate{ca.cert}),
		updated: make(chan struct{}, 1),
	}
}

func (s *rotatingSource) GetX509SVID() (*x509svid.SVID, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.svid, nil
}

func (s *rotatingSource) GetX509BundleForTrustDomain(td spiffeid.TrustDomain) (*x509bundle.Bundle, error) {
	return s.bundle.GetX509BundleForTrustDomain(td)
}

func (s *rotatingSource) rotate(svid *x509svid.SVID) {
	s.mu.Lock()
	s.svid = svid
	s.mu.Unlock()
	select {
	case s.updated <- struct{}{}:
	default:
	}
}

const (
	serverPath = "/ns/apps/sa/demo-api"
	clientPath = "/ns/apps/sa/demo-client"
)

func peerHandler(w http.ResponseWriter, r *http.Request) {
	_ = json.NewEncoder(w).Encode(map[string]string{"peer": r.TLS.PeerCertificates[0].URIs[0].String()})
}

func startServer(t *testing.T, src Source, policy string) *httptest.Server {
	t.Helper()
	authz, err := ParseAuthorizer(policy, spiffeid.RequireTrustDomainFromString("example.org"))
	if err != nil {
		t.Fatal(err)
	}
	// StartTLS would install httptest's static certificate, which crypto/tls
	// prefers over GetCertificate for SNI-less (IP) connections. Wrap the
	// listener directly instead, the same way the real server serves.
	ts := httptest.NewUnstartedServer(http.HandlerFunc(peerHandler))
	ts.Listener = tls.NewListener(ts.Listener, ServerConfig(src, authz))
	ts.Start()
	ts.URL = strings.Replace(ts.URL, "http://", "https://", 1)
	t.Cleanup(ts.Close)
	return ts
}

func get(t *testing.T, ts *httptest.Server, src Source, policy string) (string, error) {
	t.Helper()
	authz, err := ParseAuthorizer(policy, spiffeid.RequireTrustDomainFromString("example.org"))
	if err != nil {
		t.Fatal(err)
	}
	c := &http.Client{Transport: &http.Transport{TLSClientConfig: ClientConfig(src, authz)}}
	resp, err := c.Get(ts.URL)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var body map[string]string
	_ = json.NewDecoder(resp.Body).Decode(&body)
	return body["peer"], nil
}

func TestMTLSHandshake(t *testing.T) {
	ca := newTestCA(t, "example.org")
	server := newRotatingSource(ca, ca.issue(t, serverPath))
	client := newRotatingSource(ca, ca.issue(t, clientPath))
	ts := startServer(t, server, "")

	peer, err := get(t, ts, client, "spiffe://example.org"+serverPath)
	if err != nil {
		t.Fatal(err)
	}
	if peer != "spiffe://example.org"+clientPath {
		t.Fatalf("server saw peer %q", peer)
	}
}

func TestAuthorization(t *testing.T) {
	ca := newTestCA(t, "example.org")
	foreign := newTestCA(t, "evil.example")
	server := newRotatingSource(ca, ca.issue(t, serverPath))

	t.Run("client from foreign trust domain is rejected", func(t *testing.T) {
		ts := startServer(t, server, "")
		// The foreign client trusts example.org so the failure is the
		// server refusing it, not the client refusing the server.
		src := newRotatingSource(foreign, foreign.issue(t, clientPath))
		src.bundle = x509bundle.FromX509Authorities(ca.td, []*x509.Certificate{ca.cert})
		if _, err := get(t, ts, src, "example.org"); err == nil {
			t.Fatal("foreign client accepted")
		}
	})

	t.Run("server restricts to one client ID", func(t *testing.T) {
		ts := startServer(t, server, "spiffe://example.org"+clientPath)
		other := newRotatingSource(ca, ca.issue(t, "/ns/apps/sa/someone-else"))
		if _, err := get(t, ts, other, ""); err == nil {
			t.Fatal("unlisted client accepted")
		}
		allowed := newRotatingSource(ca, ca.issue(t, clientPath))
		if _, err := get(t, ts, allowed, ""); err != nil {
			t.Fatalf("listed client rejected: %v", err)
		}
	})

	t.Run("client refuses unexpected server ID", func(t *testing.T) {
		ts := startServer(t, server, "")
		client := newRotatingSource(ca, ca.issue(t, clientPath))
		if _, err := get(t, ts, client, "spiffe://example.org/ns/apps/sa/payments"); err == nil {
			t.Fatal("client accepted wrong server identity")
		}
	})
}

func TestParseAuthorizer(t *testing.T) {
	local := spiffeid.RequireTrustDomainFromString("example.org")
	for _, bad := range []string{"spiffe://", "spiffe://Example.org/x", "not a domain!"} {
		if _, err := ParseAuthorizer(bad, local); err == nil {
			t.Errorf("ParseAuthorizer(%q) accepted", bad)
		}
	}
}

// TestRotationUnderLoad swaps both server and client SVIDs every 20ms while
// the prober forces a fresh handshake per request. No request may fail.
func TestRotationUnderLoad(t *testing.T) {
	ca := newTestCA(t, "example.org")
	server := newRotatingSource(ca, ca.issue(t, serverPath))
	client := newRotatingSource(ca, ca.issue(t, clientPath))
	ts := startServer(t, server, "")

	ctx, cancel := context.WithTimeout(context.Background(), 1500*time.Millisecond)
	defer cancel()

	var rotations atomic.Int64
	go WatchRotations(ctx, server, server.updated, func(Rotation) { rotations.Add(1) })

	go func() {
		tk := time.NewTicker(20 * time.Millisecond)
		defer tk.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-tk.C:
				server.rotate(ca.issue(t, serverPath))
				client.rotate(ca.issue(t, clientPath))
			}
		}
	}()

	authz, _ := ParseAuthorizer("spiffe://example.org"+serverPath, ca.td)
	stats := Probe(ctx, ProbeConfig{URL: ts.URL, TLS: ClientConfig(client, authz), RPS: 200, Concurrency: 8}, 0, nil)

	if stats.Failures() != 0 {
		t.Fatalf("%d failures during rotation (handshake %d), last: %s", stats.Failures(), stats.HandshakeFailures, stats.LastError)
	}
	if stats.Requests < 100 {
		t.Fatalf("only %d requests sent", stats.Requests)
	}
	if stats.ServerSerials < 10 {
		t.Fatalf("client only saw %d server SVIDs; rotation not exercised", stats.ServerSerials)
	}
	if rotations.Load() < 10 {
		t.Fatalf("watcher saw %d rotations", rotations.Load())
	}
	t.Logf("requests=%d server_svids=%d rotations=%d", stats.Requests, stats.ServerSerials, rotations.Load())
}

func TestProbeCountsHandshakeFailures(t *testing.T) {
	ca := newTestCA(t, "example.org")
	foreign := newTestCA(t, "evil.example")
	ts := startServer(t, newRotatingSource(ca, ca.issue(t, serverPath)), "")

	// Client does not trust the server's CA at all.
	client := newRotatingSource(foreign, foreign.issue(t, clientPath))
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	stats := Probe(ctx, ProbeConfig{URL: ts.URL, TLS: ClientConfig(client, mustAuthz(t, "example.org")), RPS: 50}, 0, nil)
	if stats.HandshakeFailures == 0 || stats.OK != 0 {
		t.Fatalf("stats %+v: want only handshake failures", stats)
	}
}

func mustAuthz(t *testing.T, policy string) func(spiffeid.ID, [][]*x509.Certificate) error {
	t.Helper()
	a, err := ParseAuthorizer(policy, spiffeid.TrustDomain{})
	if err != nil {
		t.Fatal(err)
	}
	return a
}
