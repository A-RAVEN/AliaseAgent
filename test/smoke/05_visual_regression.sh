#!/usr/bin/env bash
# ── Step 5: Visual Regression ─────────────────────────────
# Runs Flutter integration_test with FakeSidecar + RepaintBoundary.
# Each test captures a screenshot and compares pixel-by-pixel against
# references/ baselines (1% tolerance).
# First run auto-creates baselines; subsequent runs detect visual changes.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/utils.sh"

echo "═══════════════════════════════════════════"
echo "  Step 5: Visual Regression"
echo "═══════════════════════════════════════════"
echo ""

# Run the integration test — it handles screenshot capture AND comparison
if (cd "$PROJECT_DIR" && flutter test integration_test/screenshot_test.dart --reporter compact); then
  echo ""
  echo -e "${GREEN}✓ VISUAL REGRESSION PASSED${NC}"
  exit 0
else
  echo ""
  echo -e "${RED}✗ VISUAL REGRESSION FAILED${NC}"
  echo "  Check diff details in test output above."
  exit 1
fi
