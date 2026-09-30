#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${THEOS:-}" ]]; then
  echo "THEOS is not set. Example: export THEOS=$HOME/theos" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
make clean
make package FINALPACKAGE=1
printf '\nBuilt package(s):\n'
ls -lh packages/*.deb
