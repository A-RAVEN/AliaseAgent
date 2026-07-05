#!/bin/bash
# ============================================================================
# AliasAgent Clean Rebuild Script
# Rebuilds C++ sidecar DLL via Flutter CMake's sidecar_build target,
# then deploys the DLL to additional locations.
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# -- configuration -----------------------------------------------------------
BUILD_TYPE="${1:-Debug}"           # Debug | Release | Profile
RUN_AFTER="${2:-false}"            # true to flutter run after build

SIDECAR_SRC="$PROJECT_ROOT/sidecar"
SIDECAR_BUILD="$SIDECAR_SRC/build/windows"
FLUTTER_BUILD_DIR="$PROJECT_ROOT/build/windows/x64"

# -- colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

step()  { echo -e "${GREEN}[*]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[X]${NC} $1"; exit 1; }

# ============================================================================
step "=== Clean Building AliasAgent Sidecar ($BUILD_TYPE) ==="

# ---------------------------------------------------------------------------
# 1. Clean previous build artifacts (prevents generator mismatch)
# ---------------------------------------------------------------------------
step "Cleaning previous build..."
rm -rf "$SIDECAR_BUILD"
step "Clean complete."

# ---------------------------------------------------------------------------
# 2. Ensure Flutter CMake build directory is configured
# ---------------------------------------------------------------------------
if [ ! -f "$FLUTTER_BUILD_DIR/CMakeCache.txt" ]; then
  error "Flutter CMake build dir not configured: $FLUTTER_BUILD_DIR
  Run 'flutter build windows --debug' first to generate the CMake cache,
  or 'flutter run -d windows' to let Flutter configure it automatically."
fi

# ---------------------------------------------------------------------------
# 3. Build sidecar via Flutter CMake target
# ---------------------------------------------------------------------------
step "Building sidecar via Flutter CMake (sidecar_build target)..."
cmake --build "$FLUTTER_BUILD_DIR" --config "$BUILD_TYPE" --target sidecar_build

# Verify output
DLL_PATH="$SIDECAR_BUILD/$BUILD_TYPE/sidecar.dll"
if [ ! -f "$DLL_PATH" ]; then
  error "Build failed: $DLL_PATH not found"
fi
step "Build succeeded: $DLL_PATH"

# ---------------------------------------------------------------------------
# 4. Copy DLL to deployment locations
# ---------------------------------------------------------------------------
step "Deploying DLL..."

# Location 1: Flutter runner directory (loaded by flutter run)
RUNNER_DIR="$FLUTTER_BUILD_DIR/runner/$BUILD_TYPE"
if [ -d "$RUNNER_DIR" ]; then
  cp -f "$DLL_PATH" "$RUNNER_DIR/sidecar.dll"
  step "  -> $RUNNER_DIR/sidecar.dll"
else
  warn "  Runner dir not found: $RUNNER_DIR (skipped)"
fi

# Location 2: windows/ dir (used by flutter build for bundling)
WINDOWS_DIR="$PROJECT_ROOT/windows"
cp -f "$DLL_PATH" "$WINDOWS_DIR/sidecar.dll"
step "  -> $WINDOWS_DIR/sidecar.dll"

# Location 3: Project root (for direct dart run / testing)
cp -f "$DLL_PATH" "$PROJECT_ROOT/sidecar.dll"
step "  -> $PROJECT_ROOT/sidecar.dll"

# Location 4: test/ dir
TEST_DIR="$PROJECT_ROOT/test"
if [ -d "$TEST_DIR" ]; then
  cp -f "$DLL_PATH" "$TEST_DIR/sidecar.dll"
  step "  -> $TEST_DIR/sidecar.dll"
fi

# ---------------------------------------------------------------------------
# 5. Copy dependent DLLs (libcurl, zlib) if present
# ---------------------------------------------------------------------------
for dll in libcurl.dll zlib1.dll; do
  if [ -f "$WINDOWS_DIR/$dll" ]; then
    cp -f "$WINDOWS_DIR/$dll" "$RUNNER_DIR/$dll" 2>/dev/null || true
    cp -f "$WINDOWS_DIR/$dll" "$PROJECT_ROOT/$dll" 2>/dev/null || true
  fi
done

# ---------------------------------------------------------------------------
# 6. Optional: Flutter run
# ---------------------------------------------------------------------------
if [ "$RUN_AFTER" = "true" ]; then
  step "Starting Flutter app..."
  cd "$PROJECT_ROOT"
  flutter run -d windows
fi

# ---------------------------------------------------------------------------
step "=== Done! ==="
echo ""
echo "  Sidecar DLL: $DLL_PATH"
echo "  Runner dir:  $RUNNER_DIR/sidecar.dll"
echo ""
echo "  Next: flutter run -d windows"