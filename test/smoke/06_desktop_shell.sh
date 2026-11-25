#!/usr/bin/env bash
# ── Step 06: 桌面壳冒烟（change `windows-desktop-shell` 任务 4.6） ───────────
#
# 单独跑：本步骤**不**挂进 `test/smoke/run_all.sh` 的聚合链（那条链的 04/05 会起
# 应用窗口，受 CLAUDE.md 禁开窗规则管辖）。本脚本全程**无窗口**：
#   dotnet test（纯逻辑）→ 构建壳 → `--selftest`（起核心/HTTP/停机，不建窗口与托盘）。
#
# 用法：bash test/smoke/06_desktop_shell.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

echo "═══════════════════════════════════════════"
echo "  Step 6: 桌面壳（dotnet test + 构建 + 自检，全程无窗口）"
echo "═══════════════════════════════════════════"
echo ""

fail() {
  echo ""
  echo -e "\033[0;31m✗ $1\033[0m" >&2
  exit 1
}

# 工具有两个可执行名：Git Bash / cmd 下是 `dotnet`、`powershell`，WSL 下走 Windows
# 互操作时只有 `dotnet.exe`、`powershell.exe`。两种都认（脚本本身与 shell 无关）。
find_tool() {
  local candidate
  for candidate in "$@"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      command -v "$candidate"
      return 0
    fi
  done
  return 1
}

# ── 1/5 dotnet 存在性 ────────────────────────────────────────────────
# 这个检查**刻意只放在 06 脚本内部**：塞进 `utils.sh` 的 `check_deps` 会让没装
# dotnet 的机器上既有 01–05（以及 run_all.sh 聚合）提前失败。
DOTNET="$(find_tool dotnet dotnet.exe || true)"
if [[ -z "$DOTNET" ]]; then
  echo "✗ PATH 上找不到 dotnet。" >&2
  echo "  装 .NET SDK（本仓库用 SDK 11.0.100 构建 net10 目标；仓库根 global.json 钉住版本）后重试。" >&2
  echo "  （本检查只在 06 内部：不写进 utils.sh 的 check_deps，免得拖累既有 01–05）" >&2
  exit 1
fi
DOTNET_SDK="$("$DOTNET" --version)"
GLOBAL_JSON_SDK="$(grep -o '"version"[^,]*' global.json | head -n 1 | grep -o '[0-9.]*')"
echo "[1/5] dotnet --version = $DOTNET_SDK（global.json 钉住 $GLOBAL_JSON_SDK；命令=$DOTNET）"
if [[ "${DOTNET_SDK%%.*}" != "${GLOBAL_JSON_SDK%%.*}" ]]; then
  fail "实际 SDK $DOTNET_SDK 与 global.json 钉住的 $GLOBAL_JSON_SDK 大版本不一致"
fi

POWERSHELL="$(find_tool powershell powershell.exe || true)"
if [[ -z "$POWERSHELL" ]]; then
  fail "PATH 上找不到 powershell（构建壳要用：scripts/build_desktop_shell.ps1）"
fi

# ── 2/5 web 产物（缺了先构建） ──────────────────────────────────────
if [[ ! -f web/dist/index.html ]]; then
  echo "[2/5] 缺 web/dist/index.html：先构建 web 产物（cd web && npm install && npm run build）"
  ( cd web && npm install && npm run build )
else
  echo "[2/5] web/dist/index.html 已存在（$(wc -c < web/dist/index.html | tr -d ' ') 字节）"
fi

# ── 3/5 dotnet test（纯逻辑，仓库根执行以读到 global.json） ──────────
echo ""
echo "[3/5] ${DOTNET} test shell/AliasAgent.Desktop.sln"
echo "-----------------------------------------------"
"$DOTNET" test shell/AliasAgent.Desktop.sln
echo "-----------------------------------------------"

# ── 4/5 构建壳（自包含产物；不起窗口） ──────────────────────────────
echo ""
echo "[4/5] 构建壳：${POWERSHELL} -NoProfile -File scripts/build_desktop_shell.ps1"
"$POWERSHELL" -NoProfile -File scripts/build_desktop_shell.ps1

EXE="shell/dist/AliasAgent.Desktop.exe"
LOADER="shell/dist/WebView2Loader.dll"
[[ -f "$EXE" ]] || fail "缺产物：$EXE"
[[ -f "$LOADER" ]] || fail "缺产物：$LOADER"

# ── 5/5 无窗口自检 ──────────────────────────────────────────────────
echo ""
echo "[5/5] 无窗口自检：$EXE --selftest"
echo "-----------------------------------------------"
selftest_log="$(mktemp)"
set +e
"$EXE" --selftest | tee "$selftest_log"
selftest_exit=${PIPESTATUS[0]}
set -e
echo "-----------------------------------------------"
step_lines="$(grep -c '^\[SELFTEST\]' "$selftest_log" 2>/dev/null || true)"
if [[ "$selftest_exit" -ne 0 ]]; then
  fail "自检失败（exit=$selftest_exit；步骤行数=$step_lines）"
fi
if [[ "$step_lines" -lt 14 ]]; then
  fail "自检步骤行数只有 $step_lines（期望至少 14：产物/仓库根/dart/端口/配置/两次核心各步）"
fi
echo "  自检步骤行数 = $step_lines"
rm -f "$selftest_log"

echo ""
echo "═══════════════════════════════════════════"
echo -e "\033[0;32m✓ 06 桌面壳冒烟通过：dotnet test 绿、壳构建成功、自检 exit=0、全程无窗口\033[0m"
echo "═══════════════════════════════════════════"
exit 0
