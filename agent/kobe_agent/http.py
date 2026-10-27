"""JSON over HTTPS with the standard library. Errors carry a status, never a header, a token or a URL."""

from __future__ import annotations

import json
import urllib.error
import urllib.parse
import urllib.request


class HttpError(Exception):
    message = "Request failed"

    def __str__(self) -> str:
        return self.message


class BadKey(HttpError):
    def __init__(self, status: int):
        super().__init__(status)
        self.status = status
        self.message = f"Refused ({status})"


class Offline(HttpError):
    message = "Can't reach the service right now."


class Failed(HttpError):
    def __init__(self, status: int, message: str | None = None):
        super().__init__(status)
        self.status = status
        self.message = message or f"HTTP {status}"


def request_json(url: str, *, headers: dict | None = None, method: str = "GET", body: dict | None = None,
                 form: dict | None = None, timeout: float = 10):
    """`body` is sent as JSON, `form` as application/x-www-form-urlencoded. Returns the parsed answer."""
    headers = dict(headers or {})
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    elif form is not None:
        data = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    headers.setdefault("Accept", "application/json")
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            raw = response.read()
    except urllib.error.HTTPError as e:
        if e.code in (401, 403):
            raise BadKey(e.code) from None
        raise Failed(e.code) from None
    except (urllib.error.URLError, TimeoutError, OSError):
        raise Offline() from None
    try:
        return json.loads(raw)
    except ValueError:
        raise Failed(200, "Unreadable answer") from None


get_json = request_json
