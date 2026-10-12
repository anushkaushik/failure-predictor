import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from fastapi.testclient import TestClient

import main

client = TestClient(main.app)

BODY = {
    "run_id": "test",
    "history": [
        {"iter": i * 10, "loss": 3.0 - i * 0.1, "grad_norm": 1.0,
         "stable_rank": 30.0, "weight_update_magnitude": 0.3}
        for i in range(8)
    ],
}


def test_health():
    assert client.get("/health").json()["status"] == "ok"


def test_predict_returns_probability():
    r = client.post("/predict", json=BODY)
    assert r.status_code == 200
    out = r.json()
    assert 0.0 <= out["failure_probability"] <= 1.0
    assert isinstance(out["alert"], bool)


def test_empty_history_rejected():
    r = client.post("/predict", json={"run_id": "x", "history": []})
    assert r.status_code == 422


def test_api_key_enforced(monkeypatch):
    monkeypatch.setattr(main, "API_KEY", "secret")
    assert client.post("/predict", json=BODY).status_code == 401
    assert client.post("/predict", json=BODY, headers={"X-API-Key": "secret"}).status_code == 200
