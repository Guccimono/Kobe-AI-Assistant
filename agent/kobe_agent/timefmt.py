"""Dates on the wire: ISO 8601 UTC, whole seconds, a trailing Z (what the Swift decoder reads)."""

from __future__ import annotations

from datetime import datetime, timezone


def iso(dt: datetime) -> str:
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def from_epoch(value) -> datetime | None:
    """Seconds or milliseconds (values above 10**11 are milliseconds); None stays None."""
    if value is None:
        return None
    value = float(value)
    if value > 10**11:
        value /= 1000
    return datetime.fromtimestamp(int(value), tz=timezone.utc)


def now() -> datetime:
    return datetime.now(timezone.utc)
