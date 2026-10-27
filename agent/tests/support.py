from __future__ import annotations

"""Fakes shared by the connector tests: a fetch that answers from fixtures, fixed clocks."""

import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path

from kobe_agent import http

FIXTURES = Path(__file__).parent / "fixtures"
CONTRACT = Path(__file__).parent / "contract"


def fixture(name: str):
    return json.loads((FIXTURES / f"{name}.json").read_text())


def contract(name: str):
    return json.loads((CONTRACT / f"snapshot_{name}.json").read_text())


def at(epoch: int) -> datetime:
    return datetime.fromtimestamp(epoch, tz=timezone.utc)


def utc():
    """Pins local time to UTC, so "today" is the same day on every machine."""
    os.environ["TZ"] = "UTC"
    time.tzset()


class FakeFetch:
    """Answers each request from the first route whose text is in the URL; records what was asked."""

    def __init__(self, routes: dict, error: Exception | None = None):
        self.routes = routes
        self.error = error
        self.calls: list[dict] = []

    def __call__(self, url, *, headers=None, method="GET", body=None, form=None, timeout=10):
        self.calls.append({"url": url, "headers": headers or {}, "method": method, "body": body, "form": form})
        if self.error:
            raise self.error
        target = url
        if isinstance(body, dict) and "query" in body:  # GitHub's two GraphQL queries share one URL
            target += "#activity" if "contributionsCollection" in body["query"] else "#pulse"
        for key, answer in self.routes.items():
            if key in target:
                if callable(answer):  # answers that depend on the body (two date ranges, one URL)
                    answer = answer(body or form)
                if isinstance(answer, Exception):
                    raise answer
                return answer
        raise http.Failed(404)
