// Package identity provides SPIFFE workload identity for direct mTLS between
// services, without a service mesh. X.509-SVIDs and trust bundles come from
// the SPIRE agent's Workload API socket and are rotated in place: every TLS
// handshake asks the source for the current SVID, so a rotation never needs
// a restart or a listener reload.
package identity

import (
	"context"
	"crypto/tls"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/bundle/x509bundle"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/svid/x509svid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

// Source is satisfied by *workloadapi.X509Source and by test fakes.
type Source interface {
	x509svid.Source
	x509bundle.Source
}

// NewSource connects to the Workload API. An empty socket falls back to the
// SPIFFE_ENDPOINT_SOCKET environment variable. It blocks until the first
// SVID is received or ctx expires.
func NewSource(ctx context.Context, socket string) (*workloadapi.X509Source, error) {
	var opts []workloadapi.X509SourceOption
	if socket != "" {
		opts = append(opts, workloadapi.WithClientOptions(workloadapi.WithAddr(socket)))
	}
	src, err := workloadapi.NewX509Source(ctx, opts...)
	if err != nil {
		return nil, fmt.Errorf("workload api: %w", err)
	}
	return src, nil
}

// ParseAuthorizer turns a policy string into an Authorizer:
//
//	""                              any member of the local trust domain
//	"example.org"                   any member of trust domain example.org
//	"spiffe://example.org/ns/x/sa/y[,spiffe://...]"  exactly these IDs
//
// local is the trust domain of this workload's own SVID.
func ParseAuthorizer(policy string, local spiffeid.TrustDomain) (tlsconfig.Authorizer, error) {
	policy = strings.TrimSpace(policy)
	switch {
	case policy == "":
		return tlsconfig.AuthorizeMemberOf(local), nil
	case strings.HasPrefix(policy, "spiffe://"):
		var ids []spiffeid.ID
		for _, s := range strings.Split(policy, ",") {
			id, err := spiffeid.FromString(strings.TrimSpace(s))
			if err != nil {
				return nil, fmt.Errorf("authorizer: %w", err)
			}
			ids = append(ids, id)
		}
		return tlsconfig.AuthorizeOneOf(ids...), nil
	default:
		td, err := spiffeid.TrustDomainFromString(policy)
		if err != nil {
			return nil, fmt.Errorf("authorizer: %w", err)
		}
		return tlsconfig.AuthorizeMemberOf(td), nil
	}
}

// ServerConfig returns a TLS 1.3 server config that requires a client SVID
// accepted by authz.
func ServerConfig(src Source, authz tlsconfig.Authorizer) *tls.Config {
	c := tlsconfig.MTLSServerConfig(src, src, authz)
	c.MinVersion = tls.VersionTLS13
	return c
}

// ClientConfig returns a TLS 1.3 client config that presents this
// workload's SVID and requires a server SVID accepted by authz.
func ClientConfig(src Source, authz tlsconfig.Authorizer) *tls.Config {
	c := tlsconfig.MTLSClientConfig(src, src, authz)
	c.MinVersion = tls.VersionTLS13
	return c
}

// LocalID returns the SPIFFE ID of the current SVID.
func LocalID(src x509svid.Source) (spiffeid.ID, error) {
	svid, err := src.GetX509SVID()
	if err != nil {
		return spiffeid.ID{}, err
	}
	return svid.ID, nil
}

// Rotation describes one observed SVID change.
type Rotation struct {
	ID        spiffeid.ID
	OldSerial string
	NewSerial string
	NotAfter  time.Time
}

// WatchRotations calls fn every time the source hands out an SVID with a
// different serial number. updated is the source's change notification
// channel (X509Source.Updated()); it returns when ctx is done.
func WatchRotations(ctx context.Context, src x509svid.Source, updated <-chan struct{}, fn func(Rotation)) {
	last := ""
	if svid, err := src.GetX509SVID(); err == nil {
		last = svid.Certificates[0].SerialNumber.String()
	}
	for {
		select {
		case <-ctx.Done():
			return
		case <-updated:
		}
		svid, err := src.GetX509SVID()
		if err != nil {
			slog.Warn("svid unavailable after update", "err", err)
			continue
		}
		leaf := svid.Certificates[0]
		if serial := leaf.SerialNumber.String(); serial != last {
			fn(Rotation{ID: svid.ID, OldSerial: last, NewSerial: serial, NotAfter: leaf.NotAfter})
			last = serial
		}
	}
}
