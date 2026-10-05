#!/usr/bin/env bash
# PreToolUse on Workflow: inject a forcing checkpoint that the workflow script
# MUST strictly follow the adversarial-verification spec BEFORE running.
set -euo pipefail

printf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"[Workflow 规范检查点] 运行任何 Workflow 前，必须严格遵循对抗验证规范：每个 claim/finding 派 N(≥3) 个独立怀疑者，各自被指示去 REFUTE（默认 refuted=true 若不确定），perspective-diverse 视角交叉，多数决 kill（≥多数 refute 即判该 claim 不成立）。禁止 confirm-only、禁止用「单 agent/维度、确认式」的伪对抗。若脚本是 review/verify，必须真正实现上述语义；脚本不合规就不许跑。运行前先自查 workflow 脚本是否符合此规范。[必查项：无中生有] 审查/验证类 workflow 必须包含一条专门检查「凭空发明」的任务，且要有判据、不能只写「检查是否有臆造」：①逐个列出被审工件里的每个上下限、默认值、超时、条数、次数（字符数/条数/毫秒/重试/并发/批量），逐个用命令核出处（git log -S 追引入提交、grep 常量名、读本地接口文档）；核不到出处的当场报出。②工件里凡写「按用户要求/已知限制/设计如此」的地方，回到用户原话或规范条文；对不上就标成「我加的」。③凡有截断/省略/丢弃的分支，检查三件事：有没有标记、标记里有没有说清略去了什么、调用方能不能取回完整内容；缺一件即缺陷（静默降级）。④该数字挡住用户目标时用户能不能自己改（配置项 + 文档出现在用户文档的配置键表里）；不能就报设计缺陷。⑤结论必须用命令核，不许拿「看起来合理/行业惯例/防御性编程」当理由。"}}'
