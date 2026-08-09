// Package faults injects latency, server errors and crashes into the request
// path so that canary analysis has something real to detect.
//
// Faults can be set at startup through FAULT_* environment variables (this is
// how a "bad release" is shipped: the pod template changes, so Argo Rollouts
// sees a new revision) or changed at runtime through the admin handler.
package faults

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// Latency distributions.
const (
	DistFixed   = "fixed"   // every affected request sleeps exactly Mean
	DistUniform = "uniform" // uniform in [0, 2*Mean]
	DistExp     = "exp"     // exponential with mean Mean, long p99 tail
)

// Config is the full fault state. The zero value injects nothing.
type Config struct {
	// LatencyMean is the mean added latency for affected requests.
	LatencyMean Duration `json:"latency_mean"`
	// LatencyDist is one of DistFixed, DistUniform, DistExp.
	LatencyDist string `json:"latency_dist"`
	// LatencyPercent is the share of requests (0-100) that get extra latency.
	// Left at 0 while LatencyMean is set, it means 100.
	LatencyPercent float64 `json:"latency_percent"`
	// ErrorPercent is the share of requests (0-100) answered with HTTP 500.
	ErrorPercent float64 `json:"error_percent"`
	// CrashAfter makes the process exit non-zero this long after the fault
	// is applied. Under Kubernetes this turns into CrashLoopBackOff.
	CrashAfter Duration `json:"crash_after"`
}

// Validate rejects values that would make the injector misbehave.
func (c Config) Validate() error {
	var errs []error
	if c.LatencyMean < 0 {
		errs = append(errs, errors.New("latency_mean must be >= 0"))
	}
	switch c.LatencyDist {
	case "", DistFixed, DistUniform, DistExp:
	default:
		errs = append(errs, fmt.Errorf("latency_dist %q: want fixed, uniform or exp", c.LatencyDist))
	}
	if c.LatencyPercent < 0 || c.LatencyPercent > 100 {
		errs = append(errs, errors.New("latency_percent must be within 0-100"))
	}
	if c.ErrorPercent < 0 || c.ErrorPercent > 100 {
		errs = append(errs, errors.New("error_percent must be within 0-100"))
	}
	if c.CrashAfter < 0 {
		errs = append(errs, errors.New("crash_after must be >= 0"))
	}
	return errors.Join(errs...)
}

// FromEnv builds a Config from FAULT_LATENCY, FAULT_LATENCY_DIST,
// FAULT_LATENCY_PERCENT, FAULT_ERROR_PERCENT and FAULT_CRASH_AFTER.
func FromEnv(getenv func(string) string) (Config, error) {
	var c Config
	var err error
	if v := getenv("FAULT_LATENCY"); v != "" {
		d, perr := time.ParseDuration(v)
		if perr != nil {
			return c, fmt.Errorf("FAULT_LATENCY: %w", perr)
		}
		c.LatencyMean = Duration(d)
	}
	c.LatencyDist = getenv("FAULT_LATENCY_DIST")
	if v := getenv("FAULT_LATENCY_PERCENT"); v != "" {
		if c.LatencyPercent, err = strconv.ParseFloat(v, 64); err != nil {
			return c, fmt.Errorf("FAULT_LATENCY_PERCENT: %w", err)
		}
	}
	if v := getenv("FAULT_ERROR_PERCENT"); v != "" {
		if c.ErrorPercent, err = strconv.ParseFloat(v, 64); err != nil {
			return c, fmt.Errorf("FAULT_ERROR_PERCENT: %w", err)
		}
	}
	if v := getenv("FAULT_CRASH_AFTER"); v != "" {
		d, perr := time.ParseDuration(v)
		if perr != nil {
			return c, fmt.Errorf("FAULT_CRASH_AFTER: %w", perr)
		}
		c.CrashAfter = Duration(d)
	}
	return c.normalized(), c.Validate()
}

func (c Config) normalized() Config {
	if c.LatencyDist == "" {
		c.LatencyDist = DistFixed
	}
	if c.LatencyMean > 0 && c.LatencyPercent == 0 {
		c.LatencyPercent = 100
	}
	return c
}

// Injector holds the active Config and applies it to requests.
type Injector struct {
	cfg atomic.Pointer[Config]

	// Overridable in tests.
	sleep func(time.Duration)
	rand  func() float64
	exit  func(int)

	mu    sync.Mutex
	crash *time.Timer
}

// New returns an Injector with the given initial Config.
func New(c Config) (*Injector, error) {
	in := &Injector{sleep: time.Sleep, rand: rand.Float64, exit: os.Exit}
	if err := in.Set(c); err != nil {
		return nil, err
	}
	return in, nil
}

// Get returns the active Config.
func (in *Injector) Get() Config { return *in.cfg.Load() }

// Set validates and activates c. A non-zero CrashAfter (re)arms the crash
// timer; zero disarms it.
func (in *Injector) Set(c Config) error {
	if err := c.Validate(); err != nil {
		return err
	}
	c = c.normalized()
	in.cfg.Store(&c)

	in.mu.Lock()
	defer in.mu.Unlock()
	if in.crash != nil {
		in.crash.Stop()
		in.crash = nil
	}
	if c.CrashAfter > 0 {
		in.crash = time.AfterFunc(time.Duration(c.CrashAfter), func() {
			fmt.Fprintf(os.Stderr, "fault injection: crashing after %s\n", time.Duration(c.CrashAfter))
			in.exit(2)
		})
	}
	return nil
}

// Delay returns the latency to add to one request under the active Config.
func (in *Injector) Delay() time.Duration {
	c := in.cfg.Load()
	if c.LatencyMean <= 0 || in.rand()*100 >= c.LatencyPercent {
		return 0
	}
	mean := float64(c.LatencyMean)
	switch c.LatencyDist {
	case DistUniform:
		return time.Duration(in.rand() * 2 * mean)
	case DistExp:
		// Inverse CDF; 1-u keeps the argument in (0, 1].
		return time.Duration(-math.Log(1-in.rand()) * mean)
	default:
		return time.Duration(mean)
	}
}

// ShouldFail reports whether one request should be answered with a 500.
func (in *Injector) ShouldFail() bool {
	c := in.cfg.Load()
	return c.ErrorPercent > 0 && in.rand()*100 < c.ErrorPercent
}

// Middleware applies latency and error faults before calling next.
func (in *Injector) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if d := in.Delay(); d > 0 {
			select {
			case <-r.Context().Done():
				return
			case <-in.after(d):
			}
		}
		if in.ShouldFail() {
			http.Error(w, "injected fault", http.StatusInternalServerError)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func (in *Injector) after(d time.Duration) <-chan struct{} {
	ch := make(chan struct{})
	go func() { in.sleep(d); close(ch) }()
	return ch
}

// AdminHandler serves GET (current Config) and PUT/POST (replace Config)
// on /admin/faults, and DELETE to clear all faults.
func (in *Injector) AdminHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet:
		case http.MethodPut, http.MethodPost:
			var c Config
			dec := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16))
			dec.DisallowUnknownFields()
			if err := dec.Decode(&c); err != nil {
				http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
				return
			}
			if err := in.Set(c); err != nil {
				http.Error(w, err.Error(), http.StatusUnprocessableEntity)
				return
			}
		case http.MethodDelete:
			_ = in.Set(Config{})
		default:
			w.Header().Set("Allow", "GET, PUT, POST, DELETE")
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(in.Get())
	})
}

// Duration is a time.Duration that marshals to and from "250ms"-style JSON
// strings.
type Duration time.Duration

func (d Duration) MarshalJSON() ([]byte, error) {
	return json.Marshal(time.Duration(d).String())
}

func (d *Duration) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return fmt.Errorf("duration must be a string like \"250ms\": %w", err)
	}
	if s == "" {
		*d = 0
		return nil
	}
	v, err := time.ParseDuration(s)
	if err != nil {
		return err
	}
	*d = Duration(v)
	return nil
}
