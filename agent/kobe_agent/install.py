"""Optional helper: keeps secrets and logs out of a git backup of ~/.hermes."""

import sys
from pathlib import Path

IGNORED = ("kobe/secrets/", "kobe/logs/")


def ensure_gitignore(path: Path) -> bool:
    """Appends the missing lines, never rewrites the rest. True when it changed the file."""
    path = Path(path)
    text = path.read_text() if path.exists() else ""
    missing = [line for line in IGNORED if line not in text.splitlines()]
    if not missing:
        return False
    if text and not text.endswith("\n"):
        text += "\n"
    path.write_text(text + "".join(f"{line}\n" for line in missing))
    return True


if __name__ == "__main__":
    changed = ensure_gitignore(Path(sys.argv[1]))
    print("Backup now skips kobe/secrets and kobe/logs." if changed else "Backup exclusions already there.")
