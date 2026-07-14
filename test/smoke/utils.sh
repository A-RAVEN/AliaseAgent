#!/usr/bin/env bash
# ── AliasAgent Smoke Test Utilities ───────────────────────
# Source this file in step scripts: source "$(dirname "$0")/utils.sh"
set -euo pipefail

# ── Paths ─────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
APP_EXE="$PROJECT_DIR/build/windows/x64/runner/Debug/alias_agent.exe"
OUTPUT_DIR="$SCRIPT_DIR/output"
REF_DIR="$SCRIPT_DIR/references"

# User data paths
APPDATA_DIR="$USERPROFILE/.aliasagent"
DB_PATH="$APPDATA_DIR/aliasagent.db"
LOG_PATH="$APPDATA_DIR/logs/sidecar.log"

# ── Colors ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# ── Dependency Check ──────────────────────────────────────
check_deps() {
  local missing=0
  local deps=("flutter" "dart" "sqlite3")

  echo "── Checking dependencies ──"
  for dep in "${deps[@]}"; do
    if command -v "$dep" &> /dev/null; then
      echo -e "  ${GREEN}✓${NC} $dep ($(command -v "$dep"))"
    else
      echo -e "  ${RED}✗${NC} $dep — NOT FOUND on PATH" >&2
      missing=1
    fi
  done

  # PowerShell is required for screenshots and window detection
  if powershell -Command '$PSVersionTable.PSVersion.ToString()' &>/dev/null; then
    echo -e "  ${GREEN}✓${NC} powershell"
  else
    echo -e "  ${RED}✗${NC} powershell — NOT AVAILABLE" >&2
    missing=1
  fi
  echo ""

  return $missing
}

# ── App Lifecycle ─────────────────────────────────────────
# NOTE: log messages go to stderr so stdout contains only the PID
launch_app() {
  local exe="${1:-$APP_EXE}"
  if [[ ! -f "$exe" ]]; then
    echo -e "${RED}ERROR: App executable not found: $exe${NC}" >&2
    echo "  Run 01_build.sh first." >&2
    return 1
  fi
  echo "Launching: $exe" >&2
  "$exe" &>/dev/null &
  local pid=$!
  echo "  PID: $pid" >&2
  echo "$pid"
}

kill_app() {
  local pid="${1:-}"
  if [[ -n "$pid" && "$pid" =~ ^[0-9]+$ ]]; then
    taskkill //PID "$pid" //F &>/dev/null && echo "Killed PID $pid" || true
  else
    # Fallback: kill by executable name
    taskkill //IM alias_agent.exe //F &>/dev/null && echo "Killed alias_agent.exe" || true
  fi
}

wait_for_window() {
  local title_match="${1:-alias_agent}"
  local timeout="${2:-30}"
  local elapsed=0
  local interval=1

  # Escape PowerShell -like wildcard characters in the title.
  # PowerShell -like uses [ ] ? * as wildcards. To match literal brackets,
  # wrap them as [[] and []] (PowerShell -like has no escape character).
  local escaped_title="${title_match//[/[[]}"
  escaped_title="${escaped_title//]/[]]}"

  echo "Waiting for window '$title_match' (timeout: ${timeout}s)..."

  while [[ $elapsed -lt $timeout ]]; do
    if powershell -Command "(Get-Process | Where-Object {\$_.MainWindowTitle -like '*$escaped_title*'}).Count -gt 0" 2>/dev/null | grep -q "True"; then
      echo -e "  ${GREEN}Window appeared after ${elapsed}s${NC}"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done

  echo -e "${RED}ERROR: Window '$title_match' did not appear within ${timeout}s${NC}" >&2
  return 1
}

# ── Screenshot ────────────────────────────────────────────
# Uses PowerShell CopyFromScreen to capture the full primary screen.
# Requires a Windows-style path (cygpath conversion) for .NET Save().
capture_screenshot() {
  local name="${1:-screenshot}"
  local outfile="$OUTPUT_DIR/${name}.png"

  # Convert MSYS2 path (e.g. /e/Projects/...) to Windows path (E:\Projects\...)
  local win_outfile
  win_outfile=$(cygpath -w "$outfile" 2>/dev/null || echo "$outfile")

  echo "Capturing: $outfile"

  if powershell -Command "
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
\$s = [System.Windows.Forms.Screen]::PrimaryScreen
\$b = New-Object System.Drawing.Bitmap \$s.Bounds.Width, \$s.Bounds.Height
\$g = [System.Drawing.Graphics]::FromImage(\$b)
\$g.CopyFromScreen(\$s.Bounds.X, \$s.Bounds.Y, 0, 0, \$s.Bounds.Size)
\$b.Save('$win_outfile', [System.Drawing.Imaging.ImageFormat]::Png)
\$g.Dispose(); \$b.Dispose()
" 2>/dev/null; then
    if [[ -f "$outfile" ]] && [[ -s "$outfile" ]]; then
      local size
      size=$(wc -c < "$outfile" | tr -d ' ')
      echo -e "  ${GREEN}Saved: $outfile (${size} bytes)${NC}"
      return 0
    fi
  fi

  echo -e "${RED}ERROR: Screenshot capture failed${NC}" >&2
  return 1
}

# ── Log Verification ──────────────────────────────────────
verify_logs() {
  local log="${1:-$LOG_PATH}"
  echo "Checking logs: $log"

  if [[ ! -f "$log" ]]; then
    echo -e "  ${YELLOW}WARNING: Log file not found${NC}"
    return 0
  fi

  local error_count
  error_count=$(grep -c "ERROR\|unrecognized" "$log" 2>/dev/null || echo "0")
  error_count=$(echo "$error_count" | tr -d ' ')

  if [[ "$error_count" -gt 0 ]]; then
    echo -e "  ${RED}FAIL: Found $error_count ERROR/unrecognized line(s):${NC}"
    grep -n "ERROR\|unrecognized" "$log" 2>/dev/null || true
    return 1
  else
    echo -e "  ${GREEN}✓ No ERROR or unrecognized entries${NC}"
    return 0
  fi
}

# ── Database Verification ─────────────────────────────────
verify_db() {
  local db="${1:-$DB_PATH}"
  echo "Checking database: $db"

  if [[ ! -f "$db" ]]; then
    echo -e "  ${RED}FAIL: Database file not found${NC}"
    return 1
  fi

  local failed=0

  for table in sessions messages; do
    if sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type='table' AND name='$table';" 2>/dev/null | grep -q "$table"; then
      echo -e "  ${GREEN}✓ Table '$table' exists${NC}"
    else
      echo -e "  ${RED}✗ Table '$table' MISSING${NC}"
      failed=1
    fi
  done

  local count
  count=$(sqlite3 "$db" "SELECT COUNT(*) FROM sessions;" 2>/dev/null || echo "0")
  count=$(echo "$count" | tr -d ' ')
  if [[ "$count" -gt 0 ]]; then
    echo -e "  ${GREEN}✓ $count session(s) in database${NC}"
  else
    echo -e "  ${YELLOW}⚠ No sessions found${NC}"
  fi

  return $failed
}
