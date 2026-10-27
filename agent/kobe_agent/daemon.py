"""One process, one loop: run each connector on its schedule, answer the app's requests between runs."""

from __future__ import annotations

import json
import os
import signal
import time
from pathlib import Path

from . import config, folder, secrets
from .connectors import REGISTRY
from .envelope import envelope
from .scheduler import Scheduler
from .watcher import Watcher

# Seconds, as the app's SnapshotRules.schedule.
SCHEDULES = {"stripe": 600, "github": 600, "vercel": 300, "google": 3600}
LOG_LIMIT = 1_000_000


def home() -> Path:
    return config.home()


def log(line: str) -> None:
    """One line per run: id, status, duration. Never data, never a secret. Rotated at 1 MB."""
    logs = home() / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    path = logs / "agent.log"
    if path.exists() and path.stat().st_size > LOG_LIMIT:
        os.replace(path, logs / "agent.log.1")
    with path.open("a") as f:
        f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} {line}\n")


class Agent:
    def __init__(self, registry: dict | None = None, schedules: dict | None = None):
        self.registry = dict(registry or REGISTRY)
        self.scheduler = Scheduler({id: s for id, s in (schedules or SCHEDULES).items() if id in self.registry})

    def owns(self, id: str) -> bool:
        """A key file that is there but can't be used still means Kobe Agent runs it: the run then says why."""
        try:
            return id in self.registry and secrets.load(id) is not None
        except (secrets.InsecureFile, ValueError, OSError):
            return id in self.registry

    def handle(self, request: dict) -> dict:
        id = request.get("id")
        if request.get("action") != "refresh":
            return {"ok": False, "error": "Unknown action"}
        if not isinstance(id, str) or not self.owns(id):
            return {"ok": False, "error": f"Kobe Agent doesn't run {id} yet"}
        self.run_connector(id)
        return {"ok": True, "error": None}

    def run_connector(self, id: str) -> None:
        """Never raises: a run that can't even write its file is logged, and the schedule still moves on."""
        started = time.monotonic()
        if id in self.scheduler.schedules:
            self.scheduler.begin(id)
        failed = True
        try:
            snapshot = self._run(id)
            failed = snapshot["status"] == "failed"
            path = folder.widgets() / f"{id}.json"
            if failed:
                snapshot["data"] = self._last_data(path) or snapshot["data"]
            folder.write_atomic(path, snapshot)
            log(f"{id} {snapshot['status']} {int((time.monotonic() - started) * 1000)}ms")
        except Exception as e:
            self._log_quietly(f"{id} not written ({type(e).__name__})")
        finally:
            if id in self.scheduler.schedules:
                self.scheduler.mark(id, time.time(), failed=failed)

    def _run(self, id: str) -> dict:
        try:
            secret = secrets.load(id)
        except secrets.InsecureFile as e:
            return envelope(id, "failed", "Couldn't refresh", "", {}, error=str(e))
        except (ValueError, OSError):
            return envelope(id, "failed", "Couldn't refresh", "", {}, error=f"{id} key file unreadable: set the key again")
        try:
            return self.registry[id](secret)
        except Exception as e:  # a connector bug: say which kind, never the message (it may hold anything)
            return envelope(id, "failed", "Couldn't refresh", "", {}, error=f"Internal error ({type(e).__name__})")

    @staticmethod
    def _log_quietly(line: str) -> None:
        try:
            log(line)
        except OSError:
            pass

    @staticmethod
    def _last_data(path: Path) -> dict | None:
        """The previous file's data, so a failed run keeps showing the last good numbers."""
        try:
            previous = json.loads(path.read_text())
        except (OSError, ValueError):
            return None
        if previous.get("status") in ("ok", "needs_you", "failed") and isinstance(previous.get("data"), dict) \
                and previous["data"]:
            return previous["data"]
        return None

    def tick(self) -> None:
        """Runs what is due. A connector without a key is skipped, not written: until Kobe Agent has its key the
        app's shim runs it, and a fresh agent file (even "not set up") would make the shim step aside."""
        for id in self.scheduler.due(time.time()):
            if self.owns(id):
                self.run_connector(id)
            else:
                self.scheduler.mark(id, time.time())


def run() -> None:
    agent = Agent()
    try:
        root = folder.root()
        owner = root.stat().st_uid if root.exists() else None
        watcher = Watcher(root, agent.handle, owner_uid=owner)
    except OSError as e:  # an exchange folder we can't open: say which kind, stop quietly (no traceback loop)
        Agent._log_quietly(f"cannot start ({type(e).__name__})")
        return

    def stop(*_):
        raise SystemExit(0)  # interrupts the kqueue wait; a flag would sleep until the next run

    signal.signal(signal.SIGTERM, stop)
    log("start")
    try:
        retry = watcher.poll()
        while True:
            agent.tick()
            timeout = agent.scheduler.next_wake(time.time())
            if retry:
                timeout = min(timeout, retry)
            watcher.wait(timeout)
            retry = watcher.poll()
    finally:
        watcher.close()
        log("stop")
