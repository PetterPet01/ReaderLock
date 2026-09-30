#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${THEOS:-}" ]]; then
  echo "THEOS is not set." >&2
  exit 1
fi
if [[ -z "${THEOS_DEVICE_IP:-}" ]]; then
  echo "Set THEOS_DEVICE_IP to your iPhone IP first." >&2
  exit 1
fi

cd "$(dirname "$0")/.."
make clean package install FINALPACKAGE=1
