package faults

import (
	"math"
	"math/rand/v2"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"
	"time"
)

func newTestInjector(t *testing.T, c Config) *Injector {
	t.Helper()
	in, err := New(Config{})
	if err != nil {
		t.Fatal(err)
	}
	r := rand.New(rand.NewPCG(1, 2))
	in.rand = r.Float64
	in.sleep = func(time.Duration) {}
	in.exit = func(int) { t.Error("unexpected exit") }
	if err := in.Set(c); err != nil {
		t.Fatal(err)
	}
	return in
}

func TestFromEnv(t *testing.T) {
	tests := []struct {
		name    string
		env     map[string]string
		want    Config
		wantErr string
	}{
		{name: "empty", env: nil, want: Config{LatencyDist: DistFixed}},
		{
			name: "latency implies 100 percent",
			env:  map[string]string{"FAULT_LATENCY": "300ms", "FAULT_LATENCY_DIST": "exp"},
			want: Config{LatencyMean: Duration(300 * time.Millisecond), LatencyDist: DistExp, LatencyPercent: 100},
		},
		{
			name: "all set",
			env: map[string]string{
				"FAULT_LATENCY": "1s", "FAULT_LATENCY_PERCENT": "25",
				"FAULT_ERROR_PERCENT": "7.5", "FAULT_CRASH_AFTER": "45s",
			},
			want: Config{
				LatencyMean: Duration(time.Second), LatencyDist: DistFixed, LatencyPercent: 25,
				ErrorPercent: 7.5, CrashAfter: Duration(45 * time.Second),
			},
		},
		{name: "bad duration", env: map[string]string{"FAULT_LATENCY": "fast"}, wantErr: "FAULT_LATENCY"},
		{name: "percent out of range", env: map[string]string{"FAULT_ERROR_PERCENT": "120"}, wantErr: "error_percent"},
		{name: "unknown dist", env: map[string]string{"FAULT_LATENCY_DIST": "pareto"}, wantErr: "latency_dist"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := FromEnv(func(k string) string { return tt.env[k] })
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("err = %v, want containing %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if got != tt.want {
				t.Fatalf("got %+v, want %+v", got, tt.want)
			}
		})
	}
}

func TestErrorPercentConverges(t *testing.T) {
	for _, pct := range []float64{0, 5, 50, 100} {
		in := newTestInjector(t, Config{ErrorPercent: pct})
		const n = 20000
		fails := 0
		for range n {
			if in.ShouldFail() {
				fails++
			}
		}
		got := float64(fails) / n * 100
		if math.Abs(got-pct) > 1 {
			t.Errorf("ErrorPercent=%v: observed %.2f%%", pct, got)
		}
	}
}

func TestLatencyDistributions(t *testing.T) {
	mean := 100 * time.Millisecond
	const n = 20000
	sample := func(dist string) []time.Duration {
		in := newTestInjector(t, Config{LatencyMean: Duration(mean), LatencyDist: dist, LatencyPercent: 100})
		out := make([]time.Duration, n)
		for i := range out {
			out[i] = in.Delay()
		}
		slices.Sort(out)
		return out
	}
	avg := func(ds []time.Duration) time.Duration {
		var s time.Duration
		for _, d := range ds {
			s += d
		}
		return s / time.Duration(len(ds))
	}

	fixed := sample(DistFixed)
	if fixed[0] != mean || fixed[n-1] != mean {
		t.Errorf("fixed: min %v max %v, want %v", fixed[0], fixed[n-1], mean)
	}

	uni := sample(DistUniform)
	if uni[n-1] > 2*mean {
		t.Errorf("uniform: max %v exceeds 2*mean", uni[n-1])
	}
	if a := avg(uni); a < 95*time.Millisecond || a > 105*time.Millisecond {
		t.Errorf("uniform: mean %v", a)
	}

	exp := sample(DistExp)
	if a := avg(exp); a < 95*time.Millisecond || a > 105*time.Millisecond {
		t.Errorf("exp: mean %v", a)
	}
	// p99 of an exponential is mean*ln(100) ~ 4.6x mean.
	if p99 := exp[n*99/100]; p99 < 400*time.Millisecond || p99 > 520*time.Millisecond {
		t.Errorf("exp: p99 %v, want ~460ms", p99)
	}
}

func TestLatencyPercent(t *testing.T) {
	in := newTestInjector(t, Config{LatencyMean: Duration(time.Second), LatencyPercent: 10})
	const n = 20000
	hit := 0
	for range n {
		if in.Delay() > 0 {
			hit++
		}
	}
	if got := float64(hit) / n * 100; math.Abs(got-10) > 1 {
		t.Errorf("observed %.2f%% delayed, want ~10%%", got)
	}
}

func TestMiddleware(t *testing.T) {
	ok := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })

	in := newTestInjector(t, Config{ErrorPercent: 100})
	rec := httptest.NewRecorder()
	in.Middleware(ok).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("code = %d, want 500", rec.Code)
	}

	slept := time.Duration(0)
	in = newTestInjector(t, Config{LatencyMean: Duration(250 * time.Millisecond), LatencyPercent: 100})
	in.sleep = func(d time.Duration) { slept += d }
	rec = httptest.NewRecorder()
	in.Middleware(ok).ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	if rec.Code != http.StatusOK || slept != 250*time.Millisecond {
		t.Fatalf("code = %d slept = %v", rec.Code, slept)
	}
}

func TestCrashAfter(t *testing.T) {
	in := newTestInjector(t, Config{})
	exited := make(chan int, 1)
	in.exit = func(code int) { exited <- code }

	if err := in.Set(Config{CrashAfter: Duration(10 * time.Millisecond)}); err != nil {
		t.Fatal(err)
	}
	select {
	case code := <-exited:
		if code == 0 {
			t.Fatal("crash must exit non-zero")
		}
	case <-time.After(time.Second):
		t.Fatal("did not crash")
	}

	// Clearing the fault disarms a pending crash.
	if err := in.Set(Config{CrashAfter: Duration(50 * time.Millisecond)}); err != nil {
		t.Fatal(err)
	}
	_ = in.Set(Config{})
	select {
	case <-exited:
		t.Fatal("crash fired after being cleared")
	case <-time.After(150 * time.Millisecond):
	}
}

func TestAdminHandler(t *testing.T) {
	in := newTestInjector(t, Config{})
	h := in.AdminHandler()

	do := func(method, body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, "/admin/faults", strings.NewReader(body)))
		return rec
	}

	rec := do(http.MethodPut, `{"error_percent": 20, "latency_mean": "150ms", "latency_dist": "uniform", "latency_percent": 50}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("PUT: %d %s", rec.Code, rec.Body)
	}
	want := Config{ErrorPercent: 20, LatencyMean: Duration(150 * time.Millisecond), LatencyDist: DistUniform, LatencyPercent: 50}
	if got := in.Get(); got != want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if !strings.Contains(do(http.MethodGet, "").Body.String(), `"latency_mean":"150ms"`) {
		t.Fatal("GET does not round-trip durations as strings")
	}

	if rec := do(http.MethodPut, `{"error_percent": 101}`); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("invalid config: %d", rec.Code)
	}
	if rec := do(http.MethodPut, `{"typo": 1}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("unknown field: %d", rec.Code)
	}
	if got := in.Get(); got != want {
		t.Fatal("rejected update must not change state")
	}

	if rec := do(http.MethodDelete, ""); rec.Code != http.StatusOK {
		t.Fatalf("DELETE: %d", rec.Code)
	}
	if got := in.Get(); got.ErrorPercent != 0 || got.LatencyMean != 0 {
		t.Fatalf("DELETE left %+v", got)
	}

	// latency_mean alone affects every request, same as FAULT_LATENCY.
	do(http.MethodPut, `{"latency_mean": "200ms"}`)
	if got := in.Get(); got.LatencyPercent != 100 {
		t.Fatalf("latency_percent = %v, want 100 when only latency_mean is set", got.LatencyPercent)
	}
	if rec := do(http.MethodPatch, ""); rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("PATCH: %d", rec.Code)
	}
}
