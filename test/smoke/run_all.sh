#!/usr/bin/env bash
# ── Smoke Test Runner ─────────────────────────────────────
# Unified entry point: runs all verification steps in sequence
# and produces a final pass/fail report.
#
# Usage:
#   bash test/smoke/run_all.sh
#
# Output files go to test/smoke/output/:
#   - run.log        Full console output
#   - screenshot_*.png  Captured screenshots
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

OUTPUT_LOG="$OUTPUT_DIR/run.log"

# Redirect everything to both console and log file
exec > >(tee -a "$OUTPUT_LOG") 2>&1

echo "═══════════════════════════════════════════"
echo "  AliasAgent Smoke Test Suite"
echo "  Started: $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════"
echo ""

# ── Pre-flight: check dependencies ──
echo "── Pre-flight: Dependency Check ──"
if ! check_deps; then
  echo -e "\n\033[0;31m✗ ABORTED: Missing dependencies\033[0m"
  exit 1
fi

# ── Step execution ──
declare -A RESULTS
STEPS=(
  "01_build:Build"
  "02_analyze:Analyze"
  "03_checkpoints:Checkpoints"
  "04_launch_and_verify:Launch & Verify"
  "05_visual_regression:Visual Regression"
)

for entry in "${STEPS[@]}"; do
  script="${entry%%:*}"
  label="${entry##*:}"
  echo ""
  echo "───────────────────────────────────────────"

  if bash "$SCRIPT_DIR/${script}.sh"; then
    RESULTS["$script"]="PASS"
    echo -e "\033[0;32m  ✓ $label PASSED\033[0m"
  else
    RESULTS["$script"]="FAIL"
    echo -e "\033[0;31m  ✗ $label FAILED\033[0m"
  fi
done

# ── Final Report ──
echo ""
echo "═══════════════════════════════════════════"
echo "  SMOKE TEST REPORT"
echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════"

PASS_COUNT=0
FAIL_COUNT=0

for entry in "${STEPS[@]}"; do
  script="${entry%%:*}"
  label="${entry##*:}"
  result="${RESULTS[$script]:-SKIP}"
  if [[ "$result" == "PASS" ]]; then
    echo -e "  \033[0;32m✓\033[0m $label — $result"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo -e "  \033[0;31m✗\033[0m $label — $result"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
done

echo ""
echo "  Total: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "  Log:   $OUTPUT_LOG"
echo ""

if [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "\033[0;32m  ALL_PASS\033[0m"
  exit 0
else
  echo -e "\033[0;31m  FAILURES DETECTED\033[0m"
  exit 1
fi
