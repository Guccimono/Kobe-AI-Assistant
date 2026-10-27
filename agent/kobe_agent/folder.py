"""The exchange folder: widgets/, requests/, results/. Named in config.json (exchange_folder); plain modes
(0755/0644) unless config.json says "shared": true (two macOS users: 2770/0660)."""

import json
import os
import tempfile
from pathlib import Path

from . import config

DEFAULT = "~/Library/Application Support/Kobe/exchange"


def root() -> Path:
    """KOBE_EXCHANGE_ROOT, else config.json's exchange_folder, else the default."""
    return Path(os.environ.get("KOBE_EXCHANGE_ROOT") or config.exchange_folder() or DEFAULT).expanduser()


def widgets() -> Path:
    return root() / "widgets"


def requests() -> Path:
    return root() / "requests"


def results() -> Path:
    return root() / "results"


def ensure(path: Path) -> Path:
    """Creates the folder if missing: 0755, or 2770 when shared (setgid keeps the group for files both users write)."""
    if not path.exists():
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o2770 if config.shared() else 0o755)
    return path


def write_atomic(path: Path, obj: dict) -> None:
    """Temp file in the same folder with the final mode, then rename: readers see old or new, never half."""
    ensure(path.parent)
    fd, temp = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.chmod(temp, 0o660 if config.shared() else 0o644)
        os.replace(temp, path)
    except BaseException:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise
