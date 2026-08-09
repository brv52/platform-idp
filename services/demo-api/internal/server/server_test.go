package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/brv52/platform-idp/services/demo-api/internal/faults"
)

func TestAppRoutes(t *testing.T) {
	s := New(Options{Version: "v1.2.3"})
	h := s.App()

	tests := []struct {
		method, path string
		code         int
	}{
		{http.MethodGet, "/api/v1/items", http.StatusOK},
		{http.MethodGet, "/api/v1/whoami", http.StatusOK},
		{http.MethodGet, "/healthz", http.StatusOK},
		{http.MethodPost, "/api/v1/items", http.StatusMethodNotAllowed},
		{http.MethodGet, "/api/v1/nope", http.StatusNotFound},
		{http.MethodGet, "/metrics", http.StatusNotFound}, // metrics live on the ops listener only
	}
	for _, tt := range tests {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(tt.method, tt.path, nil))
		if rec.Code != tt.code {
			t.Errorf("%s %s = %d, want %d", tt.method, tt.path, rec.Code, tt.code)
		}
	}

	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/items", nil))
	var body struct {
		Version string `json:"version"`
		Items   []item `json:"items"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&body); err != nil {
		t.Fatal(err)
	}
	if body.Version != "v1.2.3" || len(body.Items) == 0 {
		t.Fatalf("unexpected body %+v", body)
	}
}

func TestFaultsOnlyAffectAPI(t *testing.T) {
	in, err := faults.New(faults.Config{ErrorPercent: 100})
	if err != nil {
		t.Fatal(err)
	}
	s := New(Options{Faults: in, EnableAdmin: true})

	rec := httptest.NewRecorder()
	s.App().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/api/v1/items", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("api = %d, want injected 500", rec.Code)
	}

	for _, path := range []string{"/healthz"} {
		rec = httptest.NewRecorder()
		s.App().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("app %s = %d; probes must not see injected faults", path, rec.Code)
		}
	}
	for _, path := range []string{"/healthz", "/readyz", "/admin/faults"} {
		rec = httptest.NewRecorder()
		s.Ops().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("ops %s = %d", path, rec.Code)
		}
	}
}

func TestAdminDisabledByDefault(t *testing.T) {
	in, _ := faults.New(faults.Config{})
	s := New(Options{Faults: in})
	rec := httptest.NewRecorder()
	s.Ops().ServeHTTP(rec, httptest.NewRequest(http.MethodPut, "/admin/faults", strings.NewReader(`{"error_percent":100}`)))
	if rec.Code != http.StatusNotFound {
		t.Fatalf("admin reachable without EnableAdmin: %d", rec.Code)
	}
}

func TestReadiness(t *testing.T) {
	s := New(Options{})
	s.SetReady(false)
	rec := httptest.NewRecorder()
	s.Ops().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("readyz = %d during shutdown", rec.Code)
	}
}

func TestMiddlewareOrder(t *testing.T) {
	var order []string
	mw := func(name string) func(http.Handler) http.Handler {
		return func(next http.Handler) http.Handler {
			return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				order = append(order, name)
				next.ServeHTTP(w, r)
			})
		}
	}
	s := New(Options{Middleware: []func(http.Handler) http.Handler{mw("outer"), mw("inner")}})
	s.App().ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if strings.Join(order, ",") != "outer,inner" {
		t.Fatalf("order = %v", order)
	}
}
