"""The app's requests: `requests/<name>.json` in, `results/<name>.json` out. A kqueue on the folder wakes the
daemon; a file younger than 0.2 s may still be being written and waits; a file from any user but the app's is
ignored. Nothing a request contains can crash the daemon."""

from __future__ import annotations

import json
import os
import select
import time
from pathlib import Path

from . import folder
from .timefmt import iso, now as utcnow

SETTLE = 0.2


class Watcher:
    def __init__(self, root: Path, handle, *, owner_uid: int | None = None):
        self.requests = Path(root) / "requests"
        self.results = Path(root) / "results"
        self.handle = handle
        self.owner_uid = owner_uid
        folder.ensure(self.requests)
        self.kq = select.kqueue()
        self.fd = os.open(self.requests, os.O_RDONLY)
        self.event = select.kevent(self.fd, filter=select.KQ_FILTER_VNODE,
                                   flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR, fflags=select.KQ_NOTE_WRITE)
        self.kq.control([self.event], 0, 0)

    def close(self) -> None:
        self.kq.close()
        os.close(self.fd)

    def wait(self, timeout: float) -> bool:
        """Sleeps until the folder changes or `timeout` passes. True when it changed."""
        return bool(self.kq.control(None, 1, max(timeout, 0)))

    def poll(self) -> float:
        """Answers every settled request. Returns how soon to look again for one still settling, else 0."""
        retry = 0.0
        for path in sorted(self.requests.glob("*.json")):
            if path.name.startswith("."):
                continue
            try:
                info = path.stat()
            except FileNotFoundError:
                continue
            if self.owner_uid is not None and info.st_uid != self.owner_uid:
                continue
            age = time.time() - info.st_mtime
            if age < SETTLE:
                retry = SETTLE - age + 0.05
                continue
            self._answer(path)
        return retry

    def _answer(self, path: Path) -> None:
        try:
            request = json.loads(path.read_text())
            if not isinstance(request, dict):
                raise ValueError
        except (ValueError, OSError, RecursionError):
            outcome = {"ok": False, "error": "Unreadable request"}
        else:
            try:
                outcome = self.handle(request)
            except Exception:
                outcome = {"ok": False, "error": "Kobe Agent hit an internal error"}
        try:
            folder.write_atomic(self.results / path.name, {"id": path.stem, "ok": bool(outcome.get("ok")),
                                                           "error": outcome.get("error"), "done_at": iso(utcnow())})
        except OSError:
            pass  # the app gives up after its timeout; the request still goes, or it would be answered forever
        try:
            path.unlink()
        except OSError:
            pass
