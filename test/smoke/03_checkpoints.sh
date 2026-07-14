#!/usr/bin/env bash
# ── Step 3: Checkpoints ───────────────────────────────────
# Runs all existing checkpoint_X_verify.dart scripts.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_DIR="$PROJECT_DIR/test"

echo "═══════════════════════════════════════════"
echo "  Step 3: Checkpoints — dart run verify scripts"
echo "═══════════════════════════════════════════"
echo ""

cd "$PROJECT_DIR"

FAILED=()
PASSED=()

# Find and sort checkpoint files
while IFS= read -r -d '' file; do
  name=$(basename "$file")
  echo "── Running: $name ──"
  if dart run "$file" 2>&1; then
    echo -e "  \033[0;32m✓ PASSED\033[0m"
    PASSED+=("$name")
  else
    echo -e "  \033[0;31m✗ FAILED\033[0m"
    FAILED+=("$name")
  fi
  echo ""
done < <(find "$TEST_DIR" -maxdepth 1 -name 'checkpoint_*_verify.dart' -print0 | sort -z)

# ── Summary ──
echo "───────────────────────────────────────────"
echo "  Checkpoint Results: ${#PASSED[@]} passed, ${#FAILED[@]} failed"
echo "───────────────────────────────────────────"

if [[ ${#PASSED[@]} -gt 0 ]]; then
  for f in "${PASSED[@]}"; do
    echo -e "  \033[0;32m✓\033[0m $f"
  done
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
  for f in "${FAILED[@]}"; do
    echo -e "  \033[0;31m✗\033[0m $f"
  done
fi

if [[ ${#PASSED[@]} -eq 0 && ${#FAILED[@]} -eq 0 ]]; then
  echo -e "\n\033[0;31m✗ ERROR: No checkpoint verify scripts found\033[0m"
  exit 1
elif [[ ${#FAILED[@]} -eq 0 ]]; then
  echo -e "\n\033[0;32m✓ CHECKPOINTS ALL PASSED\033[0m"
  exit 0
else
  echo -e "\n\033[0;31m✗ CHECKPOINTS FAILED — ${#FAILED[@]} script(s) failed\033[0m"
  exit 1
fi
