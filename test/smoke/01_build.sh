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
  exit 0
else
  echo ""
  echo -e "\033[0;31m✗ BUILD FAILED\033[0m"
  exit 1
fi
