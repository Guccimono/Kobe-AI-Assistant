"""Stripe, read-only, with a restricted key: balance, today's charges, the next payout (port of StripeClient.swift
and SnapshotBuilders.stripe)."""

from __future__ import annotations

import base64
from datetime import datetime

from .. import http
from ..timefmt import from_epoch, iso, now as utcnow
from .common import money, not_set_up, plural, result

API = "https://api.stripe.com"
PERIOD = "today"


def _empty() -> dict:
    return {"period": PERIOD, "total": 0, "count": 0, "failed": 0, "refunds": 0, "currency": "eur", "available": 0,
            "pending": 0, "next_payout": None, "payments": []}


def _message(e: http.HttpError) -> str:
    if isinstance(e, http.BadKey):
        return "Invalid API key (401)" if e.status == 401 else \
            "This key can't read the balance: give the restricted key read access to Balance and Charges."
    return str(e)


def _charges(answer) -> list[dict]:
    out = []
    for c in (answer or {}).get("data") or []:
        if not all(isinstance(c.get(k), t) for k, t in (("id", str), ("amount", int), ("currency", str), ("status", str))):
            continue
        billing = c.get("billing_details") or {}
        out.append({"id": c["id"], "amount": c["amount"], "currency": c["currency"], "status": c["status"],
                    "customer": c.get("description") or billing.get("name") or "",
                    "at": from_epoch(c.get("created") or 0)})
    return out


def run(secret: dict | None, *, fetch=http.get_json, now: datetime | None = None) -> dict:
    now = now or utcnow()
    if not secret:
        return not_set_up("stripe", _empty(), now)
    key = secret.get("key", "")
    if not key.startswith("rk_"):
        return result("stripe", error="Use a restricted key (rk_…) with read access to Balance, Charges and Payouts.",
                      needs_you=False, ok_headline="", needs_headline="", detail="", data=_empty(), now=now)
    headers = {"Authorization": "Basic " + base64.b64encode(f"{key}:".encode()).decode()}
    start = int(now.astimezone().replace(hour=0, minute=0, second=0, microsecond=0).timestamp())
    try:
        balance = fetch(f"{API}/v1/balance", headers=headers)
        latest = _charges(fetch(f"{API}/v1/charges?limit=6", headers=headers))
        period = _charges(fetch(f"{API}/v1/charges?limit=100&created%5Bgte%5D={start}", headers=headers))
    except http.HttpError as e:
        return result("stripe", error=_message(e), needs_you=False, ok_headline="", needs_headline="", detail="",
                      data=_empty(), now=now)
    try:
        payout = (fetch(f"{API}/v1/payouts?limit=1", headers=headers).get("data") or [None])[0]
    except http.HttpError:
        payout = None  # a key without Payouts access just leaves the date out
    next_payout = from_epoch(payout.get("arrival_date")) if payout and payout.get("status") in ("pending", "in_transit") else None

    buckets = (balance.get("available") or []) + (balance.get("pending") or [])
    currency = buckets[0].get("currency", "eur") if buckets else (period[0]["currency"] if period else "eur")
    in_day = [p for p in period if p["at"].astimezone().date() == now.astimezone().date()]
    succeeded = [p for p in in_day if p["status"] == "succeeded"]
    failed = sum(1 for p in in_day if p["status"] == "failed")
    total = sum(p["amount"] for p in succeeded if p["currency"] == currency)
    data = {"period": PERIOD, "total": total, "count": len(succeeded), "failed": failed, "refunds": 0,
            "currency": currency, "available": sum(b.get("amount", 0) for b in buckets), "pending": 0,
            "next_payout": iso(next_payout) if next_payout else None,
            "payments": [{"id": p["id"], "customer": p["customer"], "plan": None, "amount": p["amount"],
                          "currency": p["currency"], "status": p["status"], "at": iso(p["at"]), "retry_at": None,
                          "url": f"https://dashboard.stripe.com/payments/{p['id']}"} for p in latest]}
    detail = f"{money(total, currency)} today · {plural(len(succeeded), 'payment')}" if succeeded else "No payments today"
    return result("stripe", error=None, needs_you=failed > 0, ok_headline="All good", needs_headline=f"{failed} failed",
                  detail=detail, data=data, now=now)
