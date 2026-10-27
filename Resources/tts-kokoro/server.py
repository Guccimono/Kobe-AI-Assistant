"""Kobe's optional speech helper: Kokoro-82M through kokoro-onnx. One JSON request per stdin line, one JSON reply per stdout line.

Request:  {"id": "1", "text": "Hello.", "voice": "af_heart", "speed": 1.0, "lang": "en-us"}
Reply:    {"id": "1", "path": "/tmp/.../1.wav", "seconds": 0.8}  or  {"id": "1", "error": "..."}
Also:     {"id": "x", "op": "voices"} -> {"id": "x", "voices": [...]}
          {"id": "x", "op": "ping"}   -> {"id": "x", "ok": true, "model": "..."}

Model files (Kokoro-82M, Apache 2.0) live in ~/Library/Application Support/Kobe/kokoro/:
kokoro-v1.0.onnx (about 310 MB) and voices-v1.0.bin (about 27 MB). They are put there by scripts/setup-kokoro.sh or by
hand (github.com/thewh1teagle/kokoro-onnx releases); nothing is downloaded here.
Logs go to stderr; the app keeps them in ~/Library/Logs/Kobe/tts.log. Requests are never logged, only error types.
"""
from __future__ import annotations

import atexit
import json
import os
import shutil
import sys
import tempfile
import time
from pathlib import Path

MODEL_DIR = Path(os.environ.get("KOBE_KOKORO_DIR", "~/Library/Application Support/Kobe/kokoro")).expanduser()
MODEL = MODEL_DIR / "kokoro-v1.0.onnx"
VOICES = MODEL_DIR / "voices-v1.0.bin"
OUT_DIR = Path(tempfile.mkdtemp(prefix="kobe-tts-"))
atexit.register(shutil.rmtree, OUT_DIR, ignore_errors=True)  # the WAVs are played at once; nothing to keep


def log(msg: str) -> None:
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} {msg}", file=sys.stderr, flush=True)


def short_espeak_data() -> str | None:
    """espeak-ng keeps its data path in a fixed-size buffer: past roughly 160 characters (a long user name is enough)
    it falls back to a build-machine path that doesn't exist. It also resolves symlinks, so a long path is copied
    once (about 19 MB) to a short folder in the temp directory instead."""
    try:
        import espeakng_loader
    except ImportError:
        return None
    data = espeakng_loader.get_data_path()
    if len(data) <= 120:
        return data
    short = Path(tempfile.gettempdir()) / "kobe-espeak-data"
    if not (short / "phontab").exists():
        shutil.rmtree(short, ignore_errors=True)
        shutil.copytree(data, short)
        log(f"espeak data copied to {short} (the original path is too long for espeak)")
    return str(short)


class Engine:
    """Lazy wrapper so the process starts fast and the model loads on first use."""

    def __init__(self, factory=None):
        self._factory = factory
        self._kokoro = None

    def _load(self):
        if self._kokoro is None:
            if not MODEL.exists() or not VOICES.exists():
                raise FileNotFoundError(f"Kokoro model missing in {MODEL_DIR}. Download the voice in Settings → Voice.")
            if self._factory is None:
                from kokoro_onnx import EspeakConfig, Kokoro  # imported late: slow, and absent in tests

                self._factory = lambda: Kokoro(str(MODEL), str(VOICES), espeak_config=EspeakConfig(data_path=short_espeak_data()))
            started = time.monotonic()
            self._kokoro = self._factory()
            log(f"model loaded in {time.monotonic() - started:.1f}s")
        return self._kokoro

    def voices(self) -> list[str]:
        return sorted(self._load().get_voices())

    def synthesize(self, req: dict) -> dict:
        text = (req.get("text") or "").strip()
        if not text:
            raise ValueError("empty text")
        kokoro = self._load()
        samples, rate = kokoro.create(
            text,
            voice=req.get("voice") or "af_heart",
            speed=float(req.get("speed") or 1.0),
            lang=req.get("lang") or "en-us",
        )
        import soundfile as sf

        path = OUT_DIR / f"{req['id']}.wav"
        sf.write(str(path), samples, rate)
        return {"path": str(path), "seconds": round(len(samples) / rate, 3)}


def handle(engine: Engine, line: str) -> dict:
    try:
        req = json.loads(line)
    except json.JSONDecodeError as e:
        return {"id": None, "error": f"bad json: {e}"}
    rid = req.get("id")
    try:
        op = req.get("op", "say")
        if op == "ping":
            return {"id": rid, "ok": True, "model": str(MODEL), "model_present": MODEL.exists() and VOICES.exists()}
        if op == "voices":
            return {"id": rid, "voices": engine.voices()}
        return {"id": rid, **engine.synthesize(req)}
    except Exception as e:  # one bad request must not kill the server
        log(f"{rid}: {type(e).__name__}")  # type only: the message may carry the request text
        return {"id": rid, "error": str(e)}


def main() -> None:
    engine = Engine()
    log(f"ready; model dir {MODEL_DIR}; model present: {MODEL.exists() and VOICES.exists()}")
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        sys.stdout.write(json.dumps(handle(engine, line)) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
