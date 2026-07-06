package main

import (
	"context"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

var (
	httpRequests = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_server_requests_total", Help: "Total HTTP requests",
	}, []string{"method", "route", "status", "service"})
	httpErrors = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "http_server_requests_errors_total", Help: "Total HTTP 5xx responses",
	}, []string{"method", "route", "service"})
	httpDuration = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name: "http_server_duration_seconds", Help: "HTTP request duration",
		Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
	}, []string{"method", "route", "service"})
)

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

func metricsMiddleware(route string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: 200}
		next(rec, r)
		dur := time.Since(start).Seconds()
		httpDuration.WithLabelValues(r.Method, route, "order-service").Observe(dur)
		httpRequests.WithLabelValues(r.Method, route, itoa(rec.status), "order-service").Inc()
		if rec.status >= 500 {
			httpErrors.WithLabelValues(r.Method, route, "order-service").Inc()
		}
	}
}

func itoa(i int) string {
	// tiny local helper to avoid importing strconv just for one call site
	if i == 0 {
		return "0"
	}
	neg := i < 0
	if neg {
		i = -i
	}
	var buf [8]byte
	pos := len(buf)
	for i > 0 {
		pos--
		buf[pos] = byte('0' + i%10)
		i /= 10
	}
	if neg {
		pos--
		buf[pos] = '-'
	}
	return string(buf[pos:])
}

// newMux wires up the routes. Extracted so tests can exercise the exact
// same routing (including method-specific patterns and PathValue) that
// production traffic goes through, instead of calling handlers directly.
func newMux(srv *server) *http.ServeMux {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", srv.healthz)
	mux.HandleFunc("GET /readyz", srv.readyz)
	mux.Handle("GET /metrics", promhttp.Handler())
	mux.HandleFunc("POST /orders", metricsMiddleware("/orders", srv.createOrder))
	mux.HandleFunc("GET /orders/{id}", metricsMiddleware("/orders/:id", srv.getOrder))
	return mux
}

func main() {
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stdout, nil)))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdownTracing, err := setupTracing(ctx)
	if err != nil {
		slog.Error("failed to init tracing", "error", err.Error())
		os.Exit(1)
	}
	defer func() { _ = shutdownTracing(context.Background()) }()

	srv := newServer()
	handler := otelhttp.NewHandler(newMux(srv), "order-service")

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	httpSrv := &http.Server{Addr: ":" + port, Handler: handler}

	go func() {
		slog.Info("order-service listening", "port", port)
		if err := httpSrv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("server error", "error", err.Error())
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(shutdownCtx)
}
