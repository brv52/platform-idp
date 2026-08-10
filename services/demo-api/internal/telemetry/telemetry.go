// Package telemetry sets up OpenTelemetry tracing and metrics.
//
// Metrics are recorded once through the OTel API and leave the process two
// ways: a Prometheus pull endpoint (scraped per pod, which is what lets the
// scrape config attach the rollouts-pod-template-hash label that canary
// analysis filters on) and, when an OTLP endpoint is configured, a periodic
// OTLP push to the collector. Traces go to OTLP only.
package telemetry

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	otelprom "go.opentelemetry.io/otel/exporters/prometheus"
	"go.opentelemetry.io/otel/metric"
	metricnoop "go.opentelemetry.io/otel/metric/noop"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
	"go.opentelemetry.io/otel/trace"
)

// LatencyBuckets are the request duration histogram boundaries in seconds.
// They are dense around the 250-500ms range the p99 SLO is set in.
var LatencyBuckets = []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1, 2.5, 5, 10}

// Config controls exporters. Standard OTEL_* env vars (endpoint, headers,
// sampler) are honoured by the SDK as usual.
type Config struct {
	ServiceName string
	Version     string
	// OTLP enables OTLP trace and metric export. When false only the
	// Prometheus endpoint is served, which is enough for unit tests and for
	// running the binary outside the cluster.
	OTLP bool
	// MetricInterval is the OTLP metric push period.
	MetricInterval time.Duration
}

// Telemetry owns the providers and the Prometheus registry.
type Telemetry struct {
	registry *prometheus.Registry
	meter    metric.Meter
	tracer   trace.Tracer
	shutdown []func(context.Context) error

	requests metric.Int64Counter
	duration metric.Float64Histogram
}

// Setup creates providers and installs them as the OTel globals.
func Setup(ctx context.Context, cfg Config) (*Telemetry, error) {
	res, err := resource.Merge(resource.Default(), resource.NewWithAttributes(
		semconv.SchemaURL,
		semconv.ServiceName(cfg.ServiceName),
		semconv.ServiceVersion(cfg.Version),
		semconv.K8SPodName(os.Getenv("POD_NAME")),
		semconv.K8SNamespaceName(os.Getenv("POD_NAMESPACE")),
	))
	if err != nil {
		return nil, fmt.Errorf("resource: %w", err)
	}

	t := &Telemetry{registry: prometheus.NewRegistry()}
	t.registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
	)

	promExp, err := otelprom.New(
		otelprom.WithRegisterer(t.registry),
		otelprom.WithoutScopeInfo(),
		otelprom.WithoutTargetInfo(),
	)
	if err != nil {
		return nil, fmt.Errorf("prometheus exporter: %w", err)
	}
	mopts := []sdkmetric.Option{
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(promExp),
		sdkmetric.WithView(sdkmetric.NewView(
			sdkmetric.Instrument{Name: "http.request.duration"},
			sdkmetric.Stream{Aggregation: sdkmetric.AggregationExplicitBucketHistogram{Boundaries: LatencyBuckets}},
		)),
	}

	topts := []sdktrace.TracerProviderOption{sdktrace.WithResource(res)}

	if cfg.OTLP {
		mexp, err := otlpmetricgrpc.New(ctx)
		if err != nil {
			return nil, fmt.Errorf("otlp metric exporter: %w", err)
		}
		interval := cfg.MetricInterval
		if interval <= 0 {
			interval = 15 * time.Second
		}
		mopts = append(mopts, sdkmetric.WithReader(sdkmetric.NewPeriodicReader(mexp, sdkmetric.WithInterval(interval))))

		texp, err := otlptracegrpc.New(ctx)
		if err != nil {
			return nil, fmt.Errorf("otlp trace exporter: %w", err)
		}
		topts = append(topts, sdktrace.WithBatcher(texp))
	}

	mp := sdkmetric.NewMeterProvider(mopts...)
	tp := sdktrace.NewTracerProvider(topts...)
	otel.SetMeterProvider(mp)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(propagation.TraceContext{}, propagation.Baggage{}))
	t.shutdown = append(t.shutdown, tp.Shutdown, mp.Shutdown)

	t.meter = mp.Meter("github.com/brv52/platform-idp/services/demo-api")
	t.tracer = tp.Tracer("github.com/brv52/platform-idp/services/demo-api")

	// Exported as http_requests_total and http_request_duration_seconds.
	if t.requests, err = t.meter.Int64Counter("http.requests",
		metric.WithDescription("HTTP requests served, by method, route and status code.")); err != nil {
		return nil, err
	}
	if t.duration, err = t.meter.Float64Histogram("http.request.duration",
		metric.WithUnit("s"),
		metric.WithDescription("HTTP request latency, by method, route and status code.")); err != nil {
		return nil, err
	}
	return t, nil
}

// MetricsHandler serves the Prometheus exposition format.
func (t *Telemetry) MetricsHandler() http.Handler {
	return promhttp.HandlerFor(t.registry, promhttp.HandlerOpts{EnableOpenMetrics: true})
}

// Middleware returns the tracing and request metrics middleware, outermost
// first, for server.Options.Middleware.
func (t *Telemetry) Middleware() []func(http.Handler) http.Handler {
	tracing := otelhttp.NewMiddleware("http.server",
		otelhttp.WithTracerProvider(otel.GetTracerProvider()),
		// Request metrics are recorded below with stable names; keep
		// otelhttp from emitting a second, differently named set.
		otelhttp.WithMeterProvider(metricnoop.NewMeterProvider()),
	)
	return []func(http.Handler) http.Handler{tracing, t.metrics}
}

func (t *Telemetry) metrics(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(rec, r)

		// ServeMux sets Pattern on the request it routes, so after next
		// returns it names the matched route ("GET /api/v1/items") rather
		// than the raw path, which keeps label cardinality bounded.
		route := r.Pattern
		if route == "" {
			route = "unmatched"
		}
		trace.SpanFromContext(r.Context()).SetName(route)

		attrs := metric.WithAttributes(
			attribute.String("method", r.Method),
			attribute.String("route", route),
			attribute.String("code", fmt.Sprint(rec.code)),
		)
		t.requests.Add(r.Context(), 1, attrs)
		t.duration.Record(r.Context(), time.Since(start).Seconds(), attrs)
	})
}

// Shutdown flushes and stops exporters.
func (t *Telemetry) Shutdown(ctx context.Context) error {
	var errs []error
	for _, fn := range t.shutdown {
		errs = append(errs, fn(ctx))
	}
	return errors.Join(errs...)
}

type statusRecorder struct {
	http.ResponseWriter
	code    int
	written bool
}

func (r *statusRecorder) WriteHeader(code int) {
	if !r.written {
		r.code, r.written = code, true
	}
	r.ResponseWriter.WriteHeader(code)
}

func (r *statusRecorder) Write(b []byte) (int, error) {
	r.written = true
	return r.ResponseWriter.Write(b)
}

// Unwrap lets http.ResponseController reach the underlying writer.
func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }
