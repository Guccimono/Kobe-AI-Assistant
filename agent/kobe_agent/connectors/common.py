"""What every connector shares: the not-set-up and failed envelopes, plurals and money (the Swift builders' copy)."""

from __future__ import annotations

from ..envelope import envelope


def not_set_up(id: str, data: dict, now) -> dict:
    return envelope(id, "not_set_up", "Not set up", f"Add the key: kobe-agent set-key {id}", data, now=now)


def bad_key_message(id: str) -> str:
    return f"The key was refused. Set it again: kobe-agent set-key {id}"


def result(id: str, *, error: str | None, needs_you: bool, ok_headline: str, needs_headline: str, detail: str,
           data: dict, now) -> dict:
    """failed when `error` is set (the daemon keeps the last good data), else needs_you or ok."""
    if error:
        return envelope(id, "failed", "Couldn't refresh", detail, data, error=error, now=now)
    return envelope(id, "needs_you" if needs_you else "ok", needs_headline if needs_you else ok_headline, detail,
                    data, now=now)


def plural(n: int, word: str) -> str:
    return f"{n} {word}{'' if n == 1 else 's'}"


def money(minor: int, currency: str) -> str:
    """"€1.28", "€128" (no cents when round), "MX$45", "CHF 3.50"."""
    symbol = {"eur": "€", "usd": "$", "gbp": "£", "mxn": "MX$"}.get(currency.lower(), currency.upper() + " ")
    sign = "-" if minor < 0 else ""
    value = abs(minor)
    cents = value % 100
    return f"{sign}{symbol}{value // 100}" + ("" if cents == 0 else f".{cents:02d}")
