# TODO

> **这是本项目的唯一待办文档。** 所有待办事项统一记录在本文件（项目根目录 `TODO.md`）。
> 位置已在 `CLAUDE.md` 中登记，请勿在其它路径另建 TODO / TODOList / 待办 等文档；
> 新增、更新、勾选待办一律改这一份。与 `docs/known-bugs.md`（已确认的缺陷）区分：
> 本文件装“尚未开始 / 已立项待做”的事项。

## 状态标记
- `[ ]` 待办（未开始）
- `[~]` 进行中
- `[x]` 已完成

---

### [ ] 上下文压缩：L1 摘要泄漏 `ASSISTANT` 角色标签 + 重复对话下 L1 摘要冗余

**性质**：真缺陷（角色标签泄漏）＋ 设计商榷（冗余收拢）。

**背景 / 证据**：live 测试 `compact_quality_live_test` 的输出
`live_real_context_output.txt`（摘要 dump）里，第 2 条 L1 摘要正文以 `ASSISTANT用户在多轮开发中…` 开头
（第 1 条却是正常开头的 `对话摘要：…`）。这条污染的摘要会**原样进入真正发给 AI 的上下文**。

**根因（已核实代码）**：
- `lib/services/compaction/model_summary_provider.dart:176-183` 的 `_messageText` 把对话转写成
  `${m.role.toUpperCase()}: ${m.content}`（即 `USER: …` / `ASSISTANT: …`）。
- 摘要模型总结某段时，把转录里的 `ASSISTANT:` 标签**原样复制进了它自己写的摘要**。
- 代码对 `summarize` / `summarizeText` 返回的文本**没有“剥离前导 USER/ASSISTANT/SYSTEM 角色标签”的兜底**
  （已有：空摘要兜底 `R1-5`、失败兜底——唯独缺“正文误带角色标签”的清洗）。
- 该 L1 摘要落盘为 `ClosedSummary`（progressive closure）后会被**复用缓存**再吐出，
  脏标签会跟着持续出现。

**次要（设计商榷）**：
- `lib/services/compaction/compaction_plan.dart` 对高度重复对话按“原始 token 累加 > T”切成多个 L1 批，
  每批独立成摘要 → 多条内容重叠的 L1 摘要（本 case 为 2 条：`[1,133]` 628 tokens / `[134,270]` 548 tokens）。
- L2“摘要之摘要”（`l2GroupCount`，超预算才收拢）本次未触发，因为 L1 投影已放得下，
  于是两条重叠摘要都被放进上下文。
- 商榷点：对“重复对话”是否应让 L2 更早收拢以压低上下文里的重复？属调优/取舍，需评估。

**期望方向（供后续 change 参考）**：
1. 给摘要结果加“剥离前导角色标签”的清洗（USER/ASSISTANT/SYSTEM 前缀），入口在
   `model_summary_provider.dart` 的返回值处或投影构建处。
2. 评估：高度重复对话下，是否让 L2 收拢更早触发，减少上下文冗余。

**来源文件**：`lib/services/compaction/model_summary_provider.dart`、
`lib/services/compaction/compaction_plan.dart`、`live_real_context_output.txt`。
