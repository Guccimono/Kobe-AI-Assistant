#!/bin/zsh
# Runs every test target: KobeKitTests (the logic), KobeTests (AppModel and the island, headless) and Kobe Agent's
# Python tests (stdlib unittest, run from agent/ so `kobe_agent` and `tests` import).
set -euo pipefail
cd "${0:A:h}/.."
swift test "$@"
(cd agent && python3 -m unittest discover -s tests -t .)
