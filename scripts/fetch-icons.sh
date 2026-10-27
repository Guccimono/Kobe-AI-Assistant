#!/bin/zsh
# Downloads the Phosphor icons Kobe uses (MIT, @phosphor-icons/core 2.1.1) into the KobeKit resources.
# The list is read from the PhosphorIcon enum in Sources/KobeKit/Icons.swift (raw value when given, else the
# case name), so the enum and the SVGs cannot drift. Plain names come from the regular weight, "-fill" names
# from the fill weight. Fails on any missing icon. ThemeTests.everyIconShipsAndLoads checks the result.
# Usage: scripts/fetch-icons.sh [--list]   (--list prints the names without downloading)
set -euo pipefail
cd "${0:A:h}/.."
DEST=Sources/KobeKit/Resources/Icons
BASE=https://unpkg.com/@phosphor-icons/core@2.1.1/assets
ENUM=Sources/KobeKit/Icons.swift

# Each `case` line holds one or more `name` or `name = "raw-value"` items, comma separated.
ICONS=("${(@f)$(
  sed -n '/^public enum PhosphorIcon/,/^}/p' "$ENUM" |
  grep -E '^[[:space:]]*case ' | sed -E 's/^[[:space:]]*case //; s#//.*$##' | tr ',' '\n' |
  sed -E 's/^[[:space:]]+|[[:space:]]+$//g' |
  awk 'NF { if ($0 ~ /=/) { sub(/^[^"]*"/, ""); sub(/".*$/, ""); print } else print }'
)}")
(( ${#ICONS} > 0 )) || { echo "no icons found in $ENUM"; exit 1; }

if [[ "${1:-}" == "--list" ]]; then print -l $ICONS; exit 0; fi

mkdir -p $DEST
for name in $ICONS; do
  if [[ $name == *-fill ]]; then url="$BASE/fill/$name.svg"; else url="$BASE/regular/$name.svg"; fi
  curl -fsSL "$url" -o "$DEST/$name.svg" || { echo "missing icon: $name ($url)"; exit 1; }
done
echo "fetched ${#ICONS} icons"
