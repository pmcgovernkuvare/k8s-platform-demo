package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func newTestServer(inventoryURL string) (*server, *http.ServeMux) {
	srv := newServer()
	srv.inventoryURL = func() string { return inventoryURL }
	return srv, newMux(srv)
}

func TestHealthz(t *testing.T) {
	_, mux := newTestServer("http://unused")
	ts := httptest.NewServer(mux)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/healthz")
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", resp.StatusCode)
	}
}

func TestCreateOrder_MissingFields(t *testing.T) {
	_, mux := newTestServer("http://unused")
	ts := httptest.NewServer(mux)
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/orders", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

func TestCreateOrder_Success(t *testing.T) {
	inv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(inventoryResponse{Item: "widget", Available: 100})
	}))
	defer inv.Close()

	_, mux := newTestServer(inv.URL)
	ts := httptest.NewServer(mux)
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/orders", "application/json", strings.NewReader(`{"item":"widget","quantity":3}`))
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("expected 201, got %d", resp.StatusCode)
	}

	var order Order
	if err := json.NewDecoder(resp.Body).Decode(&order); err != nil {
		t.Fatalf("decode failed: %v", err)
	}
	if order.Item != "widget" || order.Quantity != 3 {
		t.Fatalf("unexpected order: %+v", order)
	}
}

func TestCreateOrder_InsufficientInventory(t *testing.T) {
	inv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(inventoryResponse{Item: "widget", Available: 1})
	}))
	defer inv.Close()

	_, mux := newTestServer(inv.URL)
	ts := httptest.NewServer(mux)
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/orders", "application/json", strings.NewReader(`{"item":"widget","quantity":5}`))
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("expected 409, got %d", resp.StatusCode)
	}
}

func TestCreateOrder_InventoryUnavailable(t *testing.T) {
	_, mux := newTestServer("http://127.0.0.1:1")
	ts := httptest.NewServer(mux)
	defer ts.Close()

	resp, err := http.Post(ts.URL+"/orders", "application/json", strings.NewReader(`{"item":"widget","quantity":1}`))
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("expected 502, got %d", resp.StatusCode)
	}
}

func TestGetOrder_RoundTrip(t *testing.T) {
	inv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(inventoryResponse{Item: "widget", Available: 100})
	}))
	defer inv.Close()

	_, mux := newTestServer(inv.URL)
	ts := httptest.NewServer(mux)
	defer ts.Close()

	createResp, _ := http.Post(ts.URL+"/orders", "application/json", strings.NewReader(`{"item":"widget","quantity":2}`))
	var created Order
	_ = json.NewDecoder(createResp.Body).Decode(&created)
	createResp.Body.Close()

	getResp, err := http.Get(ts.URL + "/orders/" + created.ID)
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer getResp.Body.Close()
	if getResp.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", getResp.StatusCode)
	}
}

func TestGetOrder_NotFound(t *testing.T) {
	_, mux := newTestServer("http://unused")
	ts := httptest.NewServer(mux)
	defer ts.Close()

	resp, err := http.Get(ts.URL + "/orders/does-not-exist")
	if err != nil {
		t.Fatalf("request failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
}
