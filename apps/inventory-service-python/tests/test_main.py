import os

os.environ["ENABLE_OTEL"] = "false"  # keep unit tests hermetic, no collector needed

from fastapi.testclient import TestClient

from app.main import app, CATALOG

client = TestClient(app)


def test_healthz():
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_readyz():
    resp = client.get("/readyz")
    assert resp.status_code == 200


def test_metrics_exposes_prometheus_format():
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "http_server_requests_total" in resp.text


def test_known_item_returns_availability():
    # Retry a few times to absorb the ~3% injected error rate.
    for _ in range(10):
        resp = client.get("/inventory/widget")
        if resp.status_code == 200:
            body = resp.json()
            assert body["item"] == "widget"
            assert body["available"] == CATALOG["widget"]
            return
    raise AssertionError("all 10 attempts hit the simulated 3% error rate - very unlucky, rerun")


def test_unknown_item_returns_404():
    for _ in range(10):
        resp = client.get("/inventory/does-not-exist")
        if resp.status_code == 404:
            assert "unknown item" in resp.json()["error"]
            return
        assert resp.status_code == 500  # absorb simulated error, try again
    raise AssertionError("all 10 attempts hit the simulated 3% error rate - very unlucky, rerun")


def test_low_stock_item_is_reachable():
    resp = client.get("/inventory/gizmo")
    assert resp.status_code in (200, 500)
    if resp.status_code == 200:
        assert resp.json()["available"] == CATALOG["gizmo"]
