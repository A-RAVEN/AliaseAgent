#!/usr/bin/env bash
# ── Step 2: Analyze ───────────────────────────────────────
# Verifies no static analysis warnings exist.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "═══════════════════════════════════════════"
echo "  Step 2: Analyze — dart analyze lib/"
echo "═══════════════════════════════════════════"
echo ""

cd "$PROJECT_DIR"

if dart analyze lib/; then
  echo ""
  echo -e "\033[0;32m✓ ANALYZE PASSED — no issues found\033[0m"
  exit 0
else
  echo ""
  echo -e "\033[0;31m✗ ANALYZE FAILED — issues found (see above)\033[0m"
  exit 1
fi
