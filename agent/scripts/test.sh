#!/bin/zsh
# All Kobe Agent tests, stdlib unittest only. Run from anywhere.
cd "${0:A:h}/.." && exec python3 -m unittest discover -s tests -t . "$@"
