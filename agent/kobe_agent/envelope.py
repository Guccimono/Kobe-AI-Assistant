"""The snapshot envelope shared with the Swift app (`WidgetSnapshot`)."""

from __future__ import annotations

from datetime import datetime

from .timefmt import iso, now as utcnow

VERSION = 1
STATUS = ("ok", "needs_you", "failed", "not_set_up")


def envelope(id: str, status: str, headline: str, detail: str, data: dict, *, error: str | None = None,
             now: datetime | None = None, source: str = "agent") -> dict:
    if status not in STATUS:
        raise ValueError(f"unknown status {status!r}")
    return {
        "id": id,
        "version": VERSION,
        "updated_at": iso(now or utcnow()),
        "status": status,
        "headline": headline,
        "detail": detail,
        "error": error,
        "data": data,
        "source": source,
    }
