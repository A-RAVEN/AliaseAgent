#!/usr/bin/env bash
# ── Step 4: Launch & Verify ───────────────────────────────
# Launch app → wait for window → screenshot → log check → DB check → kill
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

echo "═══════════════════════════════════════════"
echo "  Step 4: Launch & Verify"
echo "═══════════════════════════════════════════"
echo ""

EXIT_CODE=0

# ── 4a. Launch ──
echo "── 4a. Launching application ──"
APP_PID=$(launch_app) || {
  echo -e "${RED}✗ Launch failed${NC}"
  exit 1
}
echo ""

# ── 4b. Wait for window ──
echo "── 4b. Waiting for window ──"
if wait_for_window "alias_agent" 30; then
  echo -e "  ${GREEN}✓ Window detected${NC}"
else
  echo -e "  ${RED}✗ Window detection failed${NC}"
  EXIT_CODE=1
fi
echo ""

# ── 4c. Screenshot ──
echo "── 4c. Screenshot ──"
if capture_screenshot "empty_state"; then
  echo ""
else
  EXIT_CODE=1
fi

# Give the app a moment to initialise fully
sleep 3

# ── 4d. Log verification ──
echo "── 4d. Log verification ──"
verify_logs || EXIT_CODE=1
echo ""

# ── 4e. DB verification ──
echo "── 4e. Database verification ──"
verify_db || EXIT_CODE=1
echo ""

# ── 4f. Cleanup ──
echo "── 4f. Cleanup ──"
kill_app "$APP_PID" || true
echo ""

# ── Result ──
if [[ $EXIT_CODE -eq 0 ]]; then
  echo -e "${GREEN}✓ LAUNCH & VERIFY ALL PASSED${NC}"
else
  echo -e "${RED}✗ LAUNCH & VERIFY FAILED${NC}"
fi
exit $EXIT_CODE
