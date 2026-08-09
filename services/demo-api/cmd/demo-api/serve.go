package main

import (
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

	"golang.org/x/sync/errgroup"

	"github.com/brv52/platform-idp/services/demo-api/internal/faults"
	"github.com/brv52/platform-idp/services/demo-api/internal/server"
)

type serveConfig struct {
	listen      string
	opsListen   string
	enableAdmin bool
	// drainDelay keeps serving after readiness flips so kube-proxy and the
	// Rollouts traffic router stop sending new requests first.
	drainDelay time.Duration
}

func serve(ctx context.Context, args []string) error {
	var cfg serveConfig
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.StringVar(&cfg.listen, "listen", envOr("LISTEN_ADDR", ":8080"), "app listener")
	fs.StringVar(&cfg.opsListen, "ops-listen", envOr("OPS_LISTEN_ADDR", ":9090"), "metrics, probes and admin listener")
	fs.BoolVar(&cfg.enableAdmin, "enable-admin", envBool("FAULT_ADMIN_ENABLED", false), "expose /admin/faults on the ops listener")
	fs.DurationVar(&cfg.drainDelay, "drain-delay", 5*time.Second, "delay between readiness=false and listener shutdown")
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

	srv := server.New(server.Options{
		Version:     version,
		Faults:      inj,
		EnableAdmin: cfg.enableAdmin,
	})

	servers := []*http.Server{
		newHTTPServer(cfg.listen, srv.App()),
		newHTTPServer(cfg.opsListen, srv.Ops()),
	}
	return run(ctx, srv, cfg.drainDelay, servers...)
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
