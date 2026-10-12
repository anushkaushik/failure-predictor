"""LLM Training Failure Predictor - REST API (FastAPI)."""
import json
import os
import secrets
from datetime import datetime, timezone

import joblib
import pandas as pd
from fastapi import FastAPI, Header, HTTPException, Query
from pydantic import BaseModel

from features import add_features

HERE = os.path.dirname(os.path.abspath(__file__))
bundle = joblib.load(os.path.join(HERE, "model.joblib"))
model = bundle["model"]
feature_cols = bundle["feature_cols"]
THRESHOLD = float(bundle["threshold"])

# Step 8: the API key comes from Secret Manager, injected as an env var by Cloud Run.
API_KEY = os.getenv("API_KEY")

# Step 7: results are stored in Firestore when USE_FIRESTORE=1 (set on Cloud Run).
db = None
if os.getenv("USE_FIRESTORE") == "1":
    from google.cloud import firestore

    db = firestore.Client()

app = FastAPI(title="LLM Training Failure Predictor", version="1.0")


class Row(BaseModel):
    iter: int
    loss: float
    grad_norm: float
    stable_rank: float
    weight_update_magnitude: float


class PredictRequest(BaseModel):
    run_id: str = "run"
    history: list[Row]  # recent telemetry rows, oldest first (send 6-10 rows)


def check_key(x_api_key):
    if API_KEY and not (x_api_key and secrets.compare_digest(x_api_key, API_KEY)):
        raise HTTPException(status_code=401, detail="invalid or missing API key")


def log_json(**fields):
    # One JSON object per line: Cloud Run turns this into structured Cloud Logging entries.
    print(json.dumps(fields), flush=True)


@app.get("/")
def root():
    return {"service": "LLM Training Failure Predictor", "docs": "/docs"}


@app.get("/health")
def health():
    return {"status": "ok", "firestore": db is not None, "auth": bool(API_KEY)}


@app.post("/predict")
def predict(req: PredictRequest, x_api_key: str | None = Header(default=None)):
    check_key(x_api_key)
    if not req.history:
        raise HTTPException(status_code=422, detail="history is empty")
    if len(req.history) > 500:
        raise HTTPException(status_code=422, detail="history too long (max 500 rows)")

    df = add_features(pd.DataFrame([r.model_dump() for r in req.history]))
    prob = float(model.predict_proba(df.iloc[[-1]][feature_cols])[0, 1])

    record = {
        "run_id": req.run_id,
        "iter": req.history[-1].iter,
        "failure_probability": round(prob, 4),
        "threshold": round(THRESHOLD, 4),
        "alert": prob >= THRESHOLD,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    log_json(severity="WARNING" if record["alert"] else "INFO", message="prediction", **record)
    if db is not None:
        db.collection("predictions").add(record)
    return record


@app.get("/predictions")
def predictions(run_id: str | None = None, limit: int = Query(20, ge=1, le=200),
                x_api_key: str | None = Header(default=None)):
    """Read back stored predictions from Firestore (newest first)."""
    check_key(x_api_key)
    if db is None:
        raise HTTPException(status_code=503, detail="Firestore is not enabled")
    from google.cloud import firestore

    col = db.collection("predictions")
    if run_id:
        docs = [d.to_dict() for d in col.where("run_id", "==", run_id).limit(500).stream()]
        docs.sort(key=lambda d: d["timestamp"], reverse=True)
        return docs[:limit]
    q = col.order_by("timestamp", direction=firestore.Query.DESCENDING).limit(limit)
    return [d.to_dict() for d in q.stream()]
# redeployed by CI
