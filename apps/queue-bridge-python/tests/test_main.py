import json
import os

os.environ["ENABLE_OTEL"] = "false"

from unittest.mock import MagicMock

import app.main as main_module
from fastapi.testclient import TestClient

client = TestClient(main_module.app)


def test_healthz():
    resp = client.get("/healthz")
    assert resp.status_code == 200


def test_metrics_exposes_prometheus_format():
    resp = client.get("/metrics")
    assert resp.status_code == 200
    assert "http_server_requests_total" in resp.text


def test_create_notification_enqueues_message(monkeypatch):
    fake_client = MagicMock()
    monkeypatch.setattr(main_module, "get_queue_client", lambda: fake_client)

    resp = client.post("/notifications", json={"orderId": "ord-1", "item": "widget", "quantity": 3})

    assert resp.status_code == 202
    assert resp.json() == {"status": "accepted"}
    fake_client.send_message.assert_called_once()

    # the message body is base64-encoded JSON containing the order fields
    import base64
    sent_arg = fake_client.send_message.call_args[0][0]
    decoded = json.loads(base64.b64decode(sent_arg))
    assert decoded["orderId"] == "ord-1"
    assert decoded["item"] == "widget"
    assert decoded["quantity"] == 3
    assert "traceId" in decoded and "spanId" in decoded


def test_create_notification_survives_queue_failure(monkeypatch):
    fake_client = MagicMock()
    fake_client.send_message.side_effect = RuntimeError("azurite unreachable")
    monkeypatch.setattr(main_module, "get_queue_client", lambda: fake_client)

    resp = client.post("/notifications", json={"orderId": "ord-2", "item": "gadget", "quantity": 1})

    # Must NOT surface the failure to the caller - notifications are best-effort.
    assert resp.status_code == 202


def test_create_notification_validates_body():
    resp = client.post("/notifications", json={"orderId": "ord-3"})
    assert resp.status_code == 422
