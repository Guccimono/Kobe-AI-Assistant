"""Connector secrets in ~/.hermes/kobe/secrets/<service>, mode 0600. The Kobe app writes the Stripe, GitHub and
Vercel keys there as the bare key; Google's sign-in (written by `google-auth`) is a small JSON file."""

from __future__ import annotations

import json
import os
import stat
import tempfile
from pathlib import Path

from . import config

# Services whose file is just the key, and the field the connector reads it from.
KEY_FIELD = {"stripe": "key", "github": "token", "vercel": "token"}


class InsecureFile(Exception):
    pass


def root() -> Path:
    override = os.environ.get("KOBE_AGENT_SECRETS")
    return Path(override) if override else config.home() / "secrets"


def load(name: str) -> dict | None:
    """None when the connector has no secret. A file anyone else could read is refused, not used; an empty one is
    a ValueError (the key was never typed fully)."""
    path = root() / name
    if not path.exists():
        return None
    if stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise InsecureFile(f"{path.name} must be mode 0600")
    text = path.read_text().strip()
    if not text:
        raise ValueError(f"{name} is empty")
    if name in KEY_FIELD:
        return {KEY_FIELD[name]: text}
    return json.loads(text)


def save(name: str, value: dict) -> None:
    folder = root()
    folder.mkdir(parents=True, exist_ok=True)
    os.chmod(folder, 0o700)
    # A 0600 temp file, then a rename: an interrupted save leaves the old file whole.
    fd, tmp = tempfile.mkstemp(dir=folder, prefix=".", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            if name in KEY_FIELD:
                f.write(value[KEY_FIELD[name]] + "\n")
            else:
                json.dump(value, f)
        os.replace(tmp, folder / name)
    except BaseException:
        os.unlink(tmp)
        raise
