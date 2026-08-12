package main

import (
	"cmp"
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"golang.org/x/sync/errgroup"

	"github.com/brv52/platform-idp/services/demo-api/internal/faults"
	"github.com/brv52/platform-idp/services/demo-api/internal/identity"
	"github.com/brv52/platform-idp/services/demo-api/internal/server"
	"github.com/brv52/platform-idp/services/demo-api/internal/telemetry"
)

type serveConfig struct {
	listen      string
	opsListen   string
	enableAdmin bool
	// drainDelay keeps serving after readiness flips so kube-proxy and the
	// Rollouts traffic router stop sending new requests first.
	drainDelay time.Duration

	mtls          bool
	mtlsListen    string
	mtlsAuthorize string
	spiffeSocket  string
}

func serve(ctx context.Context, args []string) error {
	var cfg serveConfig
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.StringVar(&cfg.listen, "listen", envOr("LISTEN_ADDR", ":8080"), "app listener")
	fs.StringVar(&cfg.opsListen, "ops-listen", envOr("OPS_LISTEN_ADDR", ":9090"), "metrics, probes and admin listener")
	fs.BoolVar(&cfg.enableAdmin, "enable-admin", envBool("FAULT_ADMIN_ENABLED", false), "expose /admin/faults on the ops listener")
	fs.DurationVar(&cfg.drainDelay, "drain-delay", 5*time.Second, "delay between readiness=false and listener shutdown")
	fs.BoolVar(&cfg.mtls, "mtls", envBool("MTLS_ENABLED", os.Getenv("SPIFFE_ENDPOINT_SOCKET") != ""), "serve the app over SPIFFE mTLS as well")
	fs.StringVar(&cfg.mtlsListen, "mtls-listen", envOr("MTLS_LISTEN_ADDR", ":8443"), "mTLS app listener")
	fs.StringVar(&cfg.mtlsAuthorize, "mtls-authorize", os.Getenv("MTLS_AUTHORIZE"), "allowed client SPIFFE IDs or trust domain (default: own trust domain)")
	fs.StringVar(&cfg.spiffeSocket, "spiffe-socket", "", "Workload API socket (default: $SPIFFE_ENDPOINT_SOCKET)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	fcfg, err := faults.FromEnv(os.Getenv)
	if err != nil {
		return fmt.Errorf("fault config: %w", err)
	}
	inj, err := faults.New(fcfg)
	if err != nil {
		return err
	}
	slog.Info("starting", "version", version, "faults", fcfg, "admin", cfg.enableAdmin)

	tel, err := telemetry.Setup(ctx, telemetry.Config{
		ServiceName: envOr("OTEL_SERVICE_NAME", "demo-api"),
		Version:     version,
		OTLP:        os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT") != "",
	})
	if err != nil {
		return fmt.Errorf("telemetry: %w", err)
	}
	defer func() {
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tel.Shutdown(sctx); err != nil {
			slog.Warn("telemetry shutdown", "err", err)
		}
	}()

	srv := server.New(server.Options{
		Version:     version,
		Faults:      inj,
		EnableAdmin: cfg.enableAdmin,
		Middleware:  tel.Middleware(),
		Metrics:     tel.MetricsHandler(),
	})

	servers := []*http.Server{
		newHTTPServer(cfg.listen, srv.App()),
		newHTTPServer(cfg.opsListen, srv.Ops()),
	}

	if cfg.mtls {
		src, err := waitForSource(ctx, cfg.spiffeSocket)
		if err != nil {
			return err
		}
		defer src.Close()
		id, err := identity.LocalID(src)
		if err != nil {
			return err
		}
		authz, err := identity.ParseAuthorizer(cfg.mtlsAuthorize, id.TrustDomain())
		if err != nil {
			return err
		}
		slog.Info("spiffe identity", "id", id.String(), "authorize", cmp.Or(cfg.mtlsAuthorize, id.TrustDomain().String()))
		go identity.WatchRotations(ctx, src, src.Updated(), logRotation)

		ms := newHTTPServer(cfg.mtlsListen, srv.App())
		ms.TLSConfig = identity.ServerConfig(src, authz)
		servers = append(servers, ms)
	}
	return run(ctx, srv, cfg.drainDelay, servers...)
}

// waitForSource connects to the Workload API, giving the SPIRE agent time
// to attest the pod when it starts at the same moment as the workload.
func waitForSource(ctx context.Context, socket string) (*workloadapi.X509Source, error) {
	wctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	src, err := identity.NewSource(wctx, socket)
	if err != nil {
		return nil, fmt.Errorf("no SVID within 60s: %w", err)
	}
	return src, nil
}

func logRotation(r identity.Rotation) {
	slog.Info("svid rotated", "id", r.ID.String(), "old_serial", r.OldSerial, "new_serial", r.NewSerial,
		"not_after", r.NotAfter.UTC().Format(time.RFC3339), "ttl_left", time.Until(r.NotAfter).Round(time.Second).String())
}

func newHTTPServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
}

// run serves until ctx is cancelled, then drains and shuts every server down.
func run(ctx context.Context, srv *server.Server, drain time.Duration, servers ...*http.Server) error {
	g, gctx := errgroup.WithContext(ctx)
	for _, s := range servers {
		ln, err := net.Listen("tcp", s.Addr)
		if err != nil {
			return err
		}
		slog.Info("listening", "addr", ln.Addr().String(), "tls", s.TLSConfig != nil)
		g.Go(func() error {
			var err error
			if s.TLSConfig != nil {
				err = s.ServeTLS(ln, "", "")
			} else {
				err = s.Serve(ln)
			}
			if errors.Is(err, http.ErrServerClosed) {
				return nil
			}
			return err
		})
	}

	g.Go(func() error {
		<-gctx.Done()
		srv.SetReady(false)
		if ctx.Err() != nil { // a signal, not a listener failure
			slog.Info("draining", "delay", drain)
			time.Sleep(drain)
		}
		sctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		var errs []error
		for _, s := range servers {
			errs = append(errs, s.Shutdown(sctx))
		}
		return errors.Join(errs...)
	})
	return g.Wait()
}

func envBool(key string, def bool) bool {
	v, err := strconv.ParseBool(os.Getenv(key))
	if err != nil {
		return def
	}
	return v
}
