#!/usr/bin/env bash
# PreToolUse on Workflow: inject a forcing checkpoint that the workflow script
# MUST strictly follow the adversarial-verification spec BEFORE running.
set -euo pipefail

printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"[Workflow 规范检查点] 运行任何 Workflow 前，必须严格遵循对抗验证规范：每个 claim/finding 派 N(≥3) 个独立怀疑者，各自被指示去 REFUTE（默认 refuted=true 若不确定），perspective-diverse 视角交叉，多数决 kill（≥多数 refute 即判该 claim 不成立）。禁止 confirm-only、禁止用「单 agent/维度、确认式」的伪对抗。若脚本是 review/verify，必须真正实现上述语义；脚本不合规就不许跑。运行前先自查 workflow 脚本是否符合此规范。"}}'
