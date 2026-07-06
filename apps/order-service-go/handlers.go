package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel/trace"
)

// Order is the in-memory record we hand back to edge-api. A real service
// would persist this; for the demo, in-memory is enough to prove the
// request lineage and let the load generator create traffic patterns.
type Order struct {
	ID        string    `json:"orderId"`
	Item      string    `json:"item"`
	Quantity  int       `json:"quantity"`
	CreatedAt time.Time `json:"createdAt"`
}

type orderStore struct {
	mu     sync.Mutex
	orders map[string]Order
	seq    int
}

func newOrderStore() *orderStore {
	return &orderStore{orders: make(map[string]Order)}
}

func (s *orderStore) create(item string, qty int) Order {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.seq++
	o := Order{ID: fmt.Sprintf("ord-%d", s.seq), Item: item, Quantity: qty, CreatedAt: time.Now().UTC()}
	s.orders[o.ID] = o
	return o
}

func (s *orderStore) get(id string) (Order, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	o, ok := s.orders[id]
	return o, ok
}

type server struct {
	store             *orderStore
	inventoryURL      func() string
	notificationURL   func() string
	httpClient        *http.Client
}

func newServer() *server {
	return &server{
		store: newOrderStore(),
		inventoryURL: func() string {
			if v := os.Getenv("INVENTORY_SERVICE_URL"); v != "" {
				return v
			}
			return "http://localhost:8000"
		},
		// queue-bridge is the seam into the async/event-driven side of the
		// demo: it drops a message on Azurite's "order-notifications" queue,
		// which KEDA + the .NET Azure Function pick up. Empty by default -
		// if unset, notifyOrder() below is a no-op, so this service still
		// works standalone without the Azure Functions piece deployed.
		notificationURL: func() string {
			return os.Getenv("NOTIFICATION_SERVICE_URL")
		},
		// otelhttp.NewTransport injects the W3C traceparent header into every
		// outbound request, which is what lets inventory-service continue
		// THIS trace instead of starting a new one - the second and final
		// propagation hop in the edge-api -> order-service -> inventory-service
		// chain.
		httpClient: &http.Client{
			Timeout:   3 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		},
	}
}

// logCtx returns a logger enriched with the active span's trace_id/span_id
// so log lines can be correlated with the Tempo trace and with the other
// two services' logs for the same request (see docs/request-lineage.md).
func logCtx(ctx context.Context) *slog.Logger {
	sc := trace.SpanContextFromContext(ctx)
	if !sc.IsValid() {
		return slog.Default()
	}
	return slog.Default().With("trace_id", sc.TraceID().String(), "span_id", sc.SpanID().String())
}

func (s *server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *server) readyz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

type createOrderRequest struct {
	Item     string `json:"item"`
	Quantity int    `json:"quantity"`
}

type inventoryResponse struct {
	Item      string `json:"item"`
	Available int    `json:"available"`
}

func (s *server) createOrder(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	log := logCtx(ctx)

	var req createOrderRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil || req.Item == "" || req.Quantity <= 0 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "item and positive quantity are required"})
		return
	}

	// Third hop of the lineage: order-service -> inventory-service. The
	// context (and therefore the trace) propagates automatically because
	// http.Client is wrapped by otelhttp in main.go.
	invURL := fmt.Sprintf("%s/inventory/%s", s.inventoryURL(), req.Item)
	invReq, _ := http.NewRequestWithContext(ctx, http.MethodGet, invURL, nil)
	resp, err := s.httpClient.Do(invReq)
	if err != nil {
		log.Error("inventory-service call failed", "error", err.Error())
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "inventory-service unavailable"})
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "inventory-service error"})
		return
	}

	var inv inventoryResponse
	if err := json.NewDecoder(resp.Body).Decode(&inv); err != nil {
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "invalid inventory-service response"})
		return
	}

	if inv.Available < req.Quantity {
		writeJSON(w, http.StatusConflict, map[string]string{"error": "insufficient inventory"})
		return
	}

	order := s.store.create(req.Item, req.Quantity)
	log.Info("order created", "orderId", order.ID, "item", order.Item, "quantity", order.Quantity)
	s.notifyOrder(ctx, log, order)
	writeJSON(w, http.StatusCreated, order)
}

// notifyOrder is a best-effort, non-blocking side effect: a failure here
// must never turn a successful order into a failed HTTP response. This is
// the boundary between the synchronous request path (edge-api ->
// order-service -> inventory-service, all through the mesh) and the async
// event-driven path (queue-bridge -> Azurite -> KEDA-scaled Azure
// Function). A short deadline keeps a slow/unavailable notification path
// from adding real latency to the customer-facing response.
func (s *server) notifyOrder(ctx context.Context, log *slog.Logger, order Order) {
	url := s.notificationURL()
	if url == "" {
		return // notifications piece not deployed - fine, order-service works standalone
	}

	notifyCtx, cancel := context.WithTimeout(ctx, 800*time.Millisecond)
	defer cancel()

	body, _ := json.Marshal(map[string]any{
		"orderId": order.ID, "item": order.Item, "quantity": order.Quantity,
	})
	req, err := http.NewRequestWithContext(notifyCtx, http.MethodPost, url+"/notifications", bytes.NewReader(body))
	if err != nil {
		log.Warn("could not build notification request", "error", err.Error())
		return
	}
	req.Header.Set("content-type", "application/json")

	resp, err := s.httpClient.Do(req)
	if err != nil {
		log.Warn("notification enqueue failed (order still succeeds)", "error", err.Error())
		return
	}
	defer resp.Body.Close()
}

func (s *server) getOrder(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	order, ok := s.store.get(id)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "order not found"})
		return
	}
	writeJSON(w, http.StatusOK, order)
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	var buf bytes.Buffer
	_ = json.NewEncoder(&buf).Encode(v)
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(buf.Bytes())
}
