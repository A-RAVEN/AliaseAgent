#!/usr/bin/env bash
# ── Step 1: Build ─────────────────────────────────────────
# Verifies the application compiles without errors.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "═══════════════════════════════════════════"
echo "  Step 1: Build — flutter build windows --debug"
echo "═══════════════════════════════════════════"
echo ""

cd "$PROJECT_DIR"

if flutter build windows --debug; then
  echo ""
  echo -e "\033[0;32m✓ BUILD PASSED\033[0m"
else
  echo ""
  echo -e "\033[0;31m✗ BUILD FAILED\033[0m"
  exit 1
fi

# Web client build (no window). change web-ui-core-shim: the headless core serves
# web/dist, so the smoke path must prove the web bundle builds. node_modules/dist
# are gitignored; ci restores from the committed lockfile.
echo ""
echo "── Web client build (no window) ──"
if npm --prefix web ci && npm --prefix web run build; then
  echo -e "\033[0;32m✓ WEB BUILD PASSED\033[0m"
  exit 0
else
  echo -e "\033[0;31m✗ WEB BUILD FAILED\033[0m"
  exit 1
fi
