"""Product inventory and stock management API (Flask + Cloud Firestore).

The service keeps no state on the VM. Every instance in the managed instance
group reads and writes the same Firestore database, which is what lets the
autoscaler add and remove instances freely.
"""
import os
import socket
import time
from datetime import datetime, timezone

from flask import Flask, jsonify, render_template, request
from google.cloud import firestore

app = Flask(__name__)
db = firestore.Client()
PRODUCTS = db.collection("products")
MOVEMENTS = db.collection("movements")

INSTANCE = socket.gethostname()
STARTED = datetime.now(timezone.utc).isoformat()


def now():
    return datetime.now(timezone.utc).isoformat()


def clean(doc):
    data = doc.to_dict()
    data["sku"] = doc.id
    return data


def validate(payload, partial=False):
    """Return (data, error). Only whitelisted, type-checked fields pass."""
    data = {}
    if "name" in payload or not partial:
        name = str(payload.get("name", "")).strip()
        if not name:
            return None, "name is required"
        data["name"] = name[:120]
    for key, cast in (("category", str), ("price", float), ("quantity", int), ("reorder_level", int)):
        if key in payload:
            try:
                data[key] = cast(payload[key])
            except (TypeError, ValueError):
                return None, f"{key} must be a valid {cast.__name__}"
        elif not partial:
            data[key] = cast() if key != "reorder_level" else 10
    for key in ("price", "quantity", "reorder_level"):
        if key in data and data[key] < 0:
            return None, f"{key} cannot be negative"
    return data, None


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/healthz")
def healthz():
    return jsonify(status="ok", instance=INSTANCE), 200


@app.get("/api/whoami")
def whoami():
    return jsonify(instance=INSTANCE, started=STARTED, pid=os.getpid())


@app.get("/api/products")
def list_products():
    items = [clean(d) for d in PRODUCTS.stream()]
    items.sort(key=lambda p: p["sku"])
    return jsonify(items=items, served_by=INSTANCE)


@app.post("/api/products")
def create_product():
    payload = request.get_json(silent=True) or {}
    sku = str(payload.get("sku", "")).strip().upper()
    if not sku or "/" in sku:
        return jsonify(error="sku is required and must not contain '/'"), 400
    data, err = validate(payload)
    if err:
        return jsonify(error=err), 400
    ref = PRODUCTS.document(sku)
    if ref.get().exists:
        return jsonify(error=f"{sku} already exists"), 409
    data["updated_at"] = now()
    ref.set(data)
    MOVEMENTS.add({"sku": sku, "delta": data["quantity"], "note": "initial stock", "at": now(), "by": INSTANCE})
    return jsonify(sku=sku, **data), 201


@app.put("/api/products/<sku>")
def update_product(sku):
    data, err = validate(request.get_json(silent=True) or {}, partial=True)
    if err:
        return jsonify(error=err), 400
    data.pop("quantity", None)  # stock only changes through /stock so it is always audited
    ref = PRODUCTS.document(sku.upper())
    if not ref.get().exists:
        return jsonify(error="not found"), 404
    data["updated_at"] = now()
    ref.update(data)
    return jsonify(clean(ref.get()))


@app.delete("/api/products/<sku>")
def delete_product(sku):
    ref = PRODUCTS.document(sku.upper())
    if not ref.get().exists:
        return jsonify(error="not found"), 404
    ref.delete()
    return "", 204


@firestore.transactional
def _adjust(txn, ref, delta):
    snap = ref.get(transaction=txn)
    if not snap.exists:
        return None, "not found"
    qty = snap.get("quantity") + delta
    if qty < 0:
        return None, "insufficient stock"
    txn.update(ref, {"quantity": qty, "updated_at": now()})
    return qty, None


@app.post("/api/products/<sku>/stock")
def adjust_stock(sku):
    payload = request.get_json(silent=True) or {}
    try:
        delta = int(payload.get("delta", 0))
    except (TypeError, ValueError):
        return jsonify(error="delta must be an integer"), 400
    if delta == 0:
        return jsonify(error="delta must be non-zero"), 400
    sku = sku.upper()
    qty, err = _adjust(db.transaction(), PRODUCTS.document(sku), delta)
    if err:
        return jsonify(error=err), (404 if err == "not found" else 409)
    MOVEMENTS.add({"sku": sku, "delta": delta, "note": str(payload.get("note", ""))[:200], "at": now(), "by": INSTANCE})
    return jsonify(sku=sku, quantity=qty)


@app.get("/api/movements")
def movements():
    docs = MOVEMENTS.order_by("at", direction=firestore.Query.DESCENDING).limit(25).stream()
    return jsonify(items=[d.to_dict() for d in docs])


@app.get("/api/summary")
def summary():
    items = [clean(d) for d in PRODUCTS.stream()]
    low = [p for p in items if p["quantity"] <= p["reorder_level"]]
    return jsonify(
        products=len(items),
        units=sum(p["quantity"] for p in items),
        value=round(sum(p["quantity"] * p["price"] for p in items), 2),
        low_stock=[{"sku": p["sku"], "name": p["name"], "quantity": p["quantity"]} for p in low],
        served_by=INSTANCE,
    )


@app.get("/api/burn")
def burn():
    """CPU load generator used only by the autoscaling demonstration (capped at 2 s)."""
    ms = max(0, min(int(request.args.get("ms", 500)), 2000))
    end = time.perf_counter() + ms / 1000
    n = 0
    while time.perf_counter() < end:
        n += sum(i * i for i in range(1000))
    return jsonify(burned_ms=ms, instance=INSTANCE)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
