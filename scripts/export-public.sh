#!/bin/zsh
# Exports the checkout as a fresh repository with a single commit, so the private history never leaves this Mac.
# Usage: scripts/export-public.sh [--force] [DEST]      (DEST defaults to ~/Projects/kobe/kobe-ai-assistant)
# It never creates the GitHub repository and never pushes: it prints the command for the maintainer to run.
set -euo pipefail

force=0
dest=""
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    -*) echo "Unknown option: $arg" >&2; exit 2 ;;
    *) [[ -z "$dest" ]] || { echo "Only one DEST is allowed." >&2; exit 2; }
       dest="$arg" ;;
  esac
done
dest="${dest:-$HOME/Projects/kobe/kobe-ai-assistant}"
dest="${dest/#\~/$HOME}"
src="${0:A:h}/.."
src="${src:A}"

dest="${dest:A}"
if [[ "$dest" == "/" || "$dest" == "${HOME:A}" || "$src" == "$dest" || "$src" == "$dest"/* || "$dest" == "$src"/* ]]; then
  echo "Refusing: DEST ($dest) is /, your home, the source checkout, or one of its parents or children." >&2; exit 2
fi

if [[ -e "$dest" && -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
  if (( ! force )); then
    echo "Refusing: $dest exists and is not empty. Re-run with --force to replace it." >&2; exit 1
  fi
  if [[ ! -d "$dest/.git" || ! -f "$dest/Package.swift" ]]; then
    echo "Refusing: $dest does not look like a previous export (needs .git and Package.swift); delete it yourself." >&2; exit 1
  fi
  echo "--force: this will delete $dest entirely:"
  ls -A "$dest" | sed 's/^/  /'
  read -r "reply?Delete it and re-export? [y/N] " || reply=""
  [[ "$reply" == [yY] ]] || { echo "Aborted."; exit 1; }
  rm -rf "$dest"
fi

mkdir -p "$dest"
echo "Copying the tree to $dest"
rsync -a \
  --exclude '.git' --exclude '.build' --exclude '/build' --exclude '.superpowers' --exclude '.swiftpm' \
  --exclude 'build-release.log' --exclude 'CLAUDE.local.md' \
  --exclude '/docs/superpowers' --exclude '/docs/legal' \
  --exclude '.DS_Store' --exclude '__pycache__' --exclude '*.pyc' \
  --exclude '/Resources/tts-kokoro/.venv' \
  --exclude '/scripts/publish-banned-words.txt' \
  "$src/" "$dest/"

cd "$dest"
git init -q -b main
git add -A
git add -f CLAUDE.md   # the owner's global ignore lists it; the public repo keeps it
git commit -q -m "Kobe AI Assistant 1.0"
count=$(git rev-list --count HEAD)
echo "Commits in the export: $count"
if [[ "$count" != "1" ]]; then echo "FAIL: expected exactly one commit." >&2; exit 1; fi

echo "Publish check: personal and third-party names"
# The same list as ScrubTests, read from the private checkout (the export never carries it): one word per line,
# plain text, case-insensitive; each word is escaped into the extended regex below.
words="$src/scripts/publish-banned-words.txt"
[[ -s "$words" ]] || { echo "FAIL: $words is missing or empty." >&2; exit 1; }
pattern=$(python3 -I -c '
import sys
special = set(".[]()*+?{}|^$\\")
words = [l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip() and not l.strip().startswith("#")]
print("|".join("".join("\\" + c if c in special else c for c in w) for w in words))
' "$words")
[[ -n "$pattern" ]] || { echo "FAIL: no words read from $words." >&2; exit 1; }
hits=$(grep -rn -i -E "$pattern" . --exclude-dir=.git || true)
print -r -- "$hits" | cut -c1-160
# Line-level allowlist: strip the allowed tokens from each matching line (public repo URL, the shared exchange path,
# the credit phrases, the copyright line) and keep the line as a failure if the pattern still matches the rest.
bad=$(print -r -- "$hits" | PATTERN="$pattern" python3 -I -c '
import os, re, sys
pat = re.compile(os.environ["PATTERN"], re.I)
repo = "gucci" + "mono/Kobe-AI-Assistant"
shared = "/Users/Shared/" + "hermes-" + "exchange"
copyright = "Copyright (c) 2026 Gauth" + "ier Couser" + "gue"
credit = "der" + "ive from Cou" + "cou"
by = "Cou" + "cou, by Louis Rail" + "lé"
glob = [repo, shared]
per = {
    "./LICENSE": [copyright],
    "./NOTICE": [copyright, by, credit + ". Cou" + "cou"],
    "./README.md": [credit + " by Louis Rail" + "lé"],
}
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    m = re.match(r"(\./[^:]+):\d+:(.*)$", line)
    if not m:
        print(line); continue
    f, text = m.groups()
    for tok in glob + per.get(f, []):
        text = re.sub(re.escape(tok), "", text, flags=re.I)
    if pat.search(text):
        print(line)
')
if [[ -n "$bad" ]]; then
  echo "FAIL: unexpected matches:" >&2
  print -r -- "$bad" >&2
  exit 1
fi
echo "Publish check passed (only allowed matches above)."

echo "Running the tests inside the export"
scripts/test.sh
rm -rf "$dest/.build"

echo
echo "Export ready at $dest"
echo "Next step, for the maintainer to run (this script does not):"
echo "  gh repo create guccimono/Kobe-AI-Assistant --public --source $dest --push"
