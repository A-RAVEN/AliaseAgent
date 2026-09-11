#!/usr/bin/env bash
# Fires on Write|Edit (PostToolUse). If the edited path is an OpenSpec change
# artifact (openspec/changes/.../proposal|design|spec|tasks.md), inject a forcing
# checkpoint reminder to self-review via a Workflow — so "I changed the change
# artifacts" always triggers a review instead of drifting off.
#
# Match is robust to Windows backslash paths.
set -euo pipefail

input=$(cat)
path=$(printf '%s' "$input" | grep -o '"file_path":"[^"]*"' | head -1 | sed 's/"file_path":"//; s/"$//')

if printf '%s' "$path" | grep -q 'openspec' && printf '%s' "$path" | grep -q 'changes'; then
  printf '%s' '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"[强制检查点] 你刚改了 OpenSpec change 的 artifact（proposal/design/spec/tasks）。按自审规矩（feedback-review-workflow-after-propose-and-rework）：立即对对应 change 跑一遍 review Workflow 对抗验证——确认改动正确、无新矛盾、无隐瞒/降级/删除真 bug、无越界。完成 review 前，停止一切「完成/收尾/归档/执行」表态，不要漂走跳过。"}}'
fi
