#!/usr/bin/env bash
# Verify the checked-in logo derivatives without downloading tools or models.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
apple swift "$AURE_ROOT/scripts/test-brand-assets.swift" "$AURE_ROOT"
