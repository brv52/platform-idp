package telemetry_test

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/brv52/platform-idp/services/demo-api/internal/faults"
	"github.com/brv52/platform-idp/services/demo-api/internal/server"
	"github.com/brv52/platform-idp/services/demo-api/internal/telemetry"
)

func scrape(t *testing.T, h http.Handler) string {
	t.Helper()
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/metrics", nil))
	b, _ := io.ReadAll(rec.Body)
	return string(b)
}

func TestRequestMetricsExposition(t *testing.T) {
	tel, err := telemetry.Setup(context.Background(), telemetry.Config{ServiceName: "demo-api", Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tel.Shutdown(context.Background()) })

	inj, _ := faults.New(faults.Config{})
	srv := server.New(server.Options{Faults: inj, Middleware: tel.Middleware(), Metrics: tel.MetricsHandler()})
	app := srv.App()

	hit := func(path string, n int) {
		for range n {
			app.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
		}
	}
	hit("/api/v1/items", 3)
	hit("/api/v1/does-not-exist-123", 1)
	_ = inj.Set(faults.Config{ErrorPercent: 100})
	hit("/api/v1/items", 2)

	out := scrape(t, srv.Ops())
	for _, want := range []string{
		`http_requests_total{code="200",method="GET",route="GET /api/v1/items"} 3`,
		`http_requests_total{code="500",method="GET",route="GET /api/v1/items"} 2`,
		// Unknown paths share one label value instead of leaking the raw URL.
		`http_requests_total{code="404",method="GET",route="unmatched"} 1`,
		`http_request_duration_seconds_bucket{code="200",method="GET",route="GET /api/v1/items",le="0.25"}`,
		`http_request_duration_seconds_count{code="500",method="GET",route="GET /api/v1/items"} 2`,
		`go_goroutines`,
	} {
		if !strings.Contains(out, want) {
			t.Errorf("exposition missing %q", want)
		}
	}
	for _, unwanted := range []string{"otel_scope_name", "target_info", "does-not-exist-123", "http_server_request_duration"} {
		if strings.Contains(out, unwanted) {
			t.Errorf("exposition contains %q", unwanted)
		}
	}
	if t.Failed() {
		t.Log(out)
	}
}
