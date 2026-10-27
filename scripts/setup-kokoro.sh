#!/bin/zsh
# Sets up the Kokoro voice in ~/Library/Application Support/Kobe: copies the helper from Resources/tts-kokoro
# and builds its Python environment with uv. The model files (kokoro-v1.0.onnx, voices-v1.0.bin) are not
# downloaded here: put them in …/Kobe/kokoro (they come from github.com/thewh1teagle/kokoro-onnx releases).
set -euo pipefail
cd "${0:A:h}/.."
DATA=~/Library/Application\ Support/Kobe
mkdir -p "$DATA/tts-kokoro" "$DATA/kokoro"
rsync -a --exclude .venv Resources/tts-kokoro/ "$DATA/tts-kokoro/"
uv sync --project "$DATA/tts-kokoro"
for f in kokoro-v1.0.onnx voices-v1.0.bin; do
  [[ -f "$DATA/kokoro/$f" ]] || echo "Missing model file: $DATA/kokoro/$f"
done
echo "Kokoro helper ready in $DATA/tts-kokoro"
