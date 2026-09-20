---
name: extract-summary-history
description: 把上下文压缩后「模型实际看到的上下文」抽成聊天窗口样式的文档（顺序严格 L2 → L1 → 原文）。当需要看压缩摘要长什么样、核对摘要质量、或把某次运行的投影留档时使用。
---

# extract summary history

把一次上下文压缩的结果（摘要节点 + 近端原文）导出成**只含上下文本身**的文档：像聊天窗口的历史那样，按 **L2 → L1 → 原文** 排列。

## 何时用

- 想看"压缩后的上下文到底长什么样"（尤其**摘要正文**）
- 核对摘要是否保住了关键信息（路径/决策/不变量）
- 把某次 live 运行或某个真实会话的投影**留档**

**与 UI 的分工**：应用里已有「真实上下文」页签（`lib/ui/context_view.dart`）可**实时**看；本 skill 用来产出**可留档、可对比**的文档。

## 格式（与产品一致，不许自创）

| 项 | 规则 | 依据 |
|---|---|---|
| 顺序 | **L2 → L1 → 原文** | 产品投影顺序 |
| 摘要排序 | `(covered_min_seq 升序, covered_max_seq 降序, level 降序)` —— L2 覆盖同段时排在其 L1 之前，从而**取代**它们 | `lib/main.dart` 投影组装处 |
| L1 前缀 | `## 更早上下文(压缩xN,非用户发言)` | `kSummaryMarker`，`lib/services/compaction/summary_provider.dart` |
| L2 前缀 | `## 更早上下文(压缩xN,层级2,非用户发言)` | `kLevel2SummaryMarker`，同上 |
| 原文范围 | **最后一条摘要 `covered_max_seq` 之后**的近端消息，按 `seq` 升序 | 投影语义 |
| 文档内容 | **只放上下文本身** —— 不要塞分析、表格、结论、"诚实边界" | 用户明确要求 |

## 步骤

1. **先起库抓捕器**（必须在跑测试**之前**）：
   ```powershell
   powershell -NoProfile -File tools\capture_compact_db.ps1 -DurationSec 900
   ```
2. **跑 live 用例**（另开一个 shell）：
   ```powershell
   flutter test --tags live --run-skipped integration_test/compact_quality_live_test.dart -d windows
   ```
3. **抽取**：
   ```powershell
   python tools\extract_summary_history.py --db "$env:TEMP\compact_db_captured\aliasagent.db" --out Docs\context-history.md
   ```
4. **对账**：文档里的摘要条数/覆盖区间应与运行输出里的
   `[OBS] summary node level=… covered=[a,b] token_cost=…` 逐条一致。

## 为什么必须抓库（本 skill 的关键）

- 测试的控制台输出**拿不到完整原文**：`dumpContext` 把 messages JSON 截断到 **2000 字符**
  （`integration_test/live_observability.dart` 的 `_truncate`）。
- 测试又在 `tearDown` 里**删掉临时库**。
- 所以：**跑之前先起抓捕器**，它会持续把 `%TEMP%\aliasagent_compact_*\*` 拷到
  `%TEMP%\compact_db_captured\`（连 `-wal`/`-shm` 一起拷，避免漏掉已提交状态）。

只给 `--run-output` 时，脚本会输出摘要段 + 一行"原文缺失"的注释（并写明原因），不会编造原文。

## 也能抽真实会话

脚本读的是**产品自己的表结构**（`lib/services/database_service.dart` 的 `messages` /
`summary_nodes`），所以直接指向用户的真实库也行：

```powershell
python tools\extract_summary_history.py --db "$env:USERPROFILE\.aliasagent\aliasagent.db" --session latest --out Docs\my-context.md
```

（截至 2026-09-13，真实库里 `summary_nodes` 为 0 —— 用户日常使用中还没触发过折叠，所以这条路径暂时无内容可出。）

## 边界

- 库以 **只读** 打开（`file:…?mode=ro`），不写产品数据。
- 某次运行若**没有摘要节点**（折完没超预算 → 没粗化；或压根没触发折叠），摘要段会是空的并附一句说明注释 —— 这是事实，不要补内容。
- **L2 不是每次都有**：只有当"折叠成 L1 之后**仍然超预算**"时才会粗化出 L2
  （`lib/main.dart` 的 `while (total > budget …)`）。想稳定看到 L2 需要更小的预算/更大的会话，
  见 `TODO.md` 里那条「L2 摘要之摘要本次未触发」。
