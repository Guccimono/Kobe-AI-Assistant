"""When each connector runs next, on the wall clock (macOS's monotonic clock stops while the Mac sleeps). First
runs are spread over the first 15 s after start; then every interval. A failed run retries after 30 s, doubling up
to the interval. A connector that is running is never due again until it is marked done."""

from __future__ import annotations

import time
from collections.abc import Iterable

STAGGER = 15.0
RETRY = 30.0
MAX_WAIT = 60.0


class Scheduler:
    def __init__(self, schedules: dict[str, int], *, start: float | None = None):
        self.schedules = dict(schedules)
        start = time.time() if start is None else start
        step = STAGGER / max(len(self.schedules), 1)
        self.next = {id: start + i * step for i, id in enumerate(self.schedules)}
        self.running: set[str] = set()
        self.failures: dict[str, int] = {}

    def due(self, now: float) -> list[str]:
        return [id for id, at in sorted(self.next.items(), key=lambda kv: kv[1])
                if at <= now and id not in self.running]

    def begin(self, id: str) -> None:
        self.running.add(id)

    def mark(self, id: str, now: float, *, failed: bool = False) -> None:
        self.running.discard(id)
        n = self.failures.get(id, 0) + 1 if failed else 0
        self.failures[id] = n
        wait = min(self.schedules[id], RETRY * 2 ** (n - 1)) if n else self.schedules[id]
        self.next[id] = now + wait

    def soon(self, id: str, now: float) -> None:
        """A manual refresh: due at once."""
        self.next[id] = now

    def next_wake(self, now: float, ids: Iterable[str] | None = None) -> float:
        """At most a minute: the kqueue wait doesn't count sleep, so a long one would oversleep a night."""
        waiting = [self.next[id] for id in (ids or self.next) if id not in self.running]
        return min(max(min(waiting, default=now + MAX_WAIT) - now, 0.0), MAX_WAIT)
