"""Kobe Agent's settings: ~/.hermes/kobe/config.json, written by the Kobe app. Missing or broken means defaults."""

from __future__ import annotations

import json
import os
from pathlib import Path


def home() -> Path:
    """Kobe Agent's own folder: config.json, secrets/, logs/."""
    override = os.environ.get("KOBE_AGENT_HOME")
    return Path(override) if override else Path.home() / ".hermes" / "kobe"


def load() -> dict:
    try:
        data = json.loads((home() / "config.json").read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _text(key: str) -> str | None:
    value = load().get(key)
    return value.strip() if isinstance(value, str) and value.strip() else None


def exchange_folder() -> str | None:
    return _text("exchange_folder")


def shared() -> bool:
    """True only for the two-users setup (docs/advanced-two-users.md): group-writable folders and files."""
    return load().get("shared") is True


def google_property() -> str | None:
    value = load().get("google_property")
    return str(value).strip() or None if isinstance(value, (str, int)) and not isinstance(value, bool) else None


def google_site() -> str | None:
    return _text("google_site")


def update(**values: str) -> None:
    """Merges keys into config.json (the app's own keys stay), atomically."""
    import tempfile
    folder = home()
    folder.mkdir(parents=True, exist_ok=True)
    merged = {**load(), **values}
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".config.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(merged, f, indent=2, sort_keys=True)
        os.chmod(tmp, 0o644)
        os.replace(tmp, folder / "config.json")
    except BaseException:
        os.unlink(tmp)
        raise
