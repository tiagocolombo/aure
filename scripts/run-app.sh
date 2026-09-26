#!/usr/bin/env bash
# Build (native arch, debug) and launch Aure.app for development.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
pkill -x Aure 2>/dev/null || true
AURE_ARCHS=native "$root/scripts/build-app.sh" "${1:-debug}"
open "$root/build/Aure.app"
