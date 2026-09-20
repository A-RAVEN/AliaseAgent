## Why

用户对上下文压缩有一条**长期、钉死的原始要求**（原文在 `TODO.md` 顶部「🔒 钉死的原始要求：上下文压缩的阈值」）：**阈值只能是 token 数，而且必须由「模型能装下的上下文总量 × 一个百分比」实时算出**（用户举例 25% × 100 万）；**不设条数阈值，不写死绝对数**。

现行实现偏离这条要求，而偏离的后果已经实测到：**把 L1 小摘要再合成一条 L2 摘要这件事，在真实运行中一次都没发生过** —— 真实库 `~/.aliasagent/aliasagent.db` 的 `summary_nodes` 表 **0 行**；受控测试跑到 407 条消息也只产出 **2 条 L1 摘要**（610 / 626 tokens），一条 L2 摘要都没有。也就是用户描述的「L2 在被收集够之前就被丢弃了」。

三处确凿偏离（2026-09-13 读代码核实，指针见下）：

1. **条数门槛**：合成 L2 的判据除了 token 阈值，还要求「至少要有 2 条」（`main.dart` 收拢循环里的 `consecutiveL1 >= 2 && groupCount >= 2`）—— 这正是用户禁止的"条数阈值"。
2. **写死的绝对下限**：分批下限 `CompactionEngine._minBatchRaw(T)` = `max(1, max(T ~/ 2, 1025))`，那个 `1025` 与模型容量无关。
3. **写死的绝对上限**：摘要请求在 `sidecar/src/model_gateway.cpp` 里写死 `max_tokens = 1024`，同样与模型容量无关（而 `Docs/DeepSeekAPIDoc.md` 记载 `max_tokens` 的取值上限是 384K、非思考模式默认 8K）。

4. **触发口径**（第四处，2026-09-13 用户当场指出）：用户 2026-08-29 定下的统一规则是「**从最旧累计，累计超过阈值就把这一批整体压一次成上一级**」，而且**两层同一条**（原文那一层也是攒够阈值就压，不等窗口装满）。实现却是"**装不下才压**" —— `CompactionEngine._foldTail` 里 `totalProxy <= budget` 直接返回、什么都不压；规范里也写成"投影达到 `maxContextTokens` 时才压"。结果：窗口还有大片空余时，一条摘要都不会产生。

5. **每会话压缩上限（审查发现后补记，第一版一字未提）**：`lib/main.dart` 里有 `kMaxFoldsPerSession = 30`（**条数门槛**）与 `kMaxFoldTokensPerSession = 500000`（**与窗口无关的写死绝对数**），超限后"压原文"和"合成 L2"**同时永久停摆**（合成 L2 的唯一入口只被那两条路径调用，而节点只增不减）。按本变更自己的算术，它比阈值先咬合 ⇒ **真实配置下 L2 依然一次都不会出现**。

外加一处**机制封顶**（这不是"取值"问题，是"到底能不能够到"的问题）：L1 摘要一落盘就被当成"已冻结、永不再动"（`_loadClosedSegments` 把库里所有节点都当"已冻结"载入，`buildTree` 的注释写明 `never re-folded or re-shaped`），**只有本轮新产出、还没落盘的那一两条**才能参与合成 L2 ⇒ 能参与合成的条数天生封顶在"一次压缩新产出的 1-2 条"，跨轮次攒到阈值在数学上不可能。

## What Changes

- **阈值改成算出来的**：新增每个 agent 类型一项配置 `compaction_threshold_percent`（缺省 **25**，与用户举例一致），阈值 = **模型能装下的上下文总量 × 这个百分比**，只在**一个地方**算出来、全流程都用它；删掉 `CompactionEngine._batchThreshold` 和收拢循环里两处写死的"容量除以 2"。
- **删掉所有条数门槛**：合成 L2 摘要的判据只剩「从最旧开始，把 L1 摘要的**实测** token 相加，首次超过阈值」。单条摘要自己就超过阈值时**照常尝试合成**（不再有"至少 2 条"的拦截），由**实测判据**承担（合成出来的 L2 摘要必须比被它替换掉的那几条 L1 摘要之和更小），不再用计数去挡。
- **把每会话压缩上限整套删干净**（第五处偏离）：`kMaxFoldsPerSession = 30`（条数门槛）、`kMaxFoldTokensPerSession = 500000`（与窗口无关的写死绝对数）、两个 getter、两个判据函数、`_callModel` 与后台压缩里的**两处早退**、以及把它钉成预期行为的那个用例，全部删除（删用例属修改验收标准，**已获用户明确授权**）；活文档里描述这道上限的表述一并清掉。它量的不是"花了多少钱"，而是"这个会话已经产出过多少条摘要"（只增不减），越过一次就**永久关闭压缩**，**触发后的后果比它要防的成本失控更糟** ⇒ 用户 2026-09-13：「没有任何留着的理由」（见 design 的 D9、tasks 第 5 组）。
- **摘要长度不再由本设计写死，并连带修规范**：`sidecar/src/model_gateway.cpp` 不再写死 `max_tokens = 1024`；同时补一份 **`model-gateway` 的规范变更**（现生效规范里仍写着摘要 profile 的 `max_tokens` 应为 512-1024），并同步更新那条把它钉死的 C++ 断言。
- **触发口径改回统一规则**（用户 2026-08-29 定下、2026-09-13 重申）：**两层都是"从最旧累加、累计超过阈值就把这一批整体压一次成上一级"，不等窗口装满** —— 原文累计超过阈值就压成 L1 摘要，L1 摘要的实测 token 累计超过阈值就合成 L2 摘要。**模型容量只保留兜底作用**：压完、合并完仍超容量时，最旧的那部分这次不发（磁盘数据不删），它不再是"要不要开始压"的开关。
- **删掉设计侧写死的绝对 token 数**：①`_minBatchRaw` 里的 `1025` 去掉，改为纯由阈值派生；②摘要请求不再由本设计指定 `max_tokens`（改用模型自己的默认值，见 `Docs/DeepSeekAPIDoc.md`），`thinking.type = "disabled"` 保持不变。
- **L1 摘要不再"一落盘就冻结"**：已落盘的 L1 摘要仍然**直接复用文本**（绝不重新去压它覆盖的原文），但**保留"可以被合成进一条 L2 摘要"的资格**；L2 摘要本身永不再被合成（只做两级）。这样「L1 摘要实测 token 相加超过阈值」这件事**跨轮次真的能攒到**，L2 摘要才有出现的可能。
- **新增"真的含 L2 摘要"的测试用例**：断言**发给模型的上下文里含 L2 摘要的标记**、`summary_nodes` 里存在 `level = 2` 的行、且被合成掉的 L1 摘要不再重复出现；并覆盖「跨两轮压缩才攒够阈值」的用例（用来证明"不再冻结"）。
- **会改变既有行为（规范层）**：`openspec/specs/context-compaction` 里"阈值 = 容量除以 2"的表述改为百分比式；行为上 L2 摘要会真的出现（以前几乎不会）。

**已拍板的范围决定（用户 2026-09-13 逐条通过，详见 design 顶部那张表）**：①授权更新那三处既有测试的期望值（不得借机放宽或删除断言）；②百分比缺省值就取 25%，先落地、实测再调；③基线规范的小节头**只改本变更要改的那两份**（`context-compaction` 与 `model-gateway`，归档必须先有它们）—— **实测修正**：这两份不但小节头是旧格式，还都缺 `## Purpose`，两份都要补；其余 **36 份**同样不合规的基线 spec 另开一单，不在本变更做；④删掉每会话上限后**先不补**成本护栏，并如实写明该意图暂时无人承担；⑤同文件里"压缩确实省"那条用例保留；⑥"最近的对话保留多少原文"先不与阈值解耦；⑦真实模型那条用例放在最后跑；⑧百分比不做界面，只放配置文件。

**不做**（明确划界）：不做第三级摘要；不改"由 AI 挑选批次分界"的机制；不改"某段不进本次请求 ≠ 删掉数据"；不改界面；不改 `summary_nodes` 表结构（`level` 列已存在）。

## Capabilities

### New Capabilities

（无）

### Modified Capabilities

- `context-compaction`：压缩阈值从写死的"容量除以 2"改为「模型容量 × 每个 agent 配置的百分比」；删除合成 L2 摘要的条数门槛；**把触发口径改回统一规则**（两层都是"累计超过阈值就压一次成上一级"，不等窗口装满；模型容量只保留兜底作用）；L1 摘要改为跨轮次可累加、可被合成进一条 L2 摘要；补上"阈值必须够得着"的约束与含摘要的验收场景。

- `model-gateway`：摘要 profile 不再由压缩设计指定 `max_tokens`（现规范写的是"SHALL be 512-1024"，与新的设计要求冲突，必须同步改），`thinking.type = "disabled"` 保持不变。

## Impact

**下面这份清单是 apply 完成后按 `git status` 核对过的实际落地范围**（初版列过的 `model_summary_provider.dart` 与 `seam_selector.dart` 最终**没有改动**，已删除）。

- **产品代码**：`lib/services/compaction/compaction_plan.dart`（阈值只在 `thresholdTokens` 一处算出、分批下限、切分方向、"可参与合成"标记、收拢分组）、`lib/main.dart`（触发与收拢循环、按层级区分冻结、可注入的摘要节点仓储、删除每会话上限）、`lib/models/agent_type_config.dart`（新配置字段 `compaction_threshold_percent` 与其缺省/非法值回落）、`sidecar/src/model_gateway.cpp`（摘要请求不再写死 `max_tokens`）。
- **测试**：`test/unit/compaction_engine_test.dart`（阈值按比例算出 / 不再有写死的 1025 下限 / 没有条数门槛 / 切分方向 / 可参与合成）、`test/unit/agent_registry_test.dart`（新配置的解析与缺省）、`test/unit/seam_selector_test.dart`（按新阈值重新取尺寸参数）、`test/integration/compaction_projection_test.dart`（**新增含 L2 摘要的用例**、跨轮次累加、顺序不变式、被拒不再重试）、`test/integration/cost_discipline_test.dart`（删掉把每会话上限钉成预期行为的用例，保留"压缩确实省"那条）、`test/integration/background_fold_test.dart`（把与已删设计同名的措辞改说清）、`sidecar/test/http_client_test.cpp`（两条摘要用例）、`integration_test/compact_quality_live_test.dart`（真实模型产出 L2 摘要 + `captureLiveShot` 截图 + `read_image` 目视验收）。
- **规范/文档**：`openspec/specs/context-compaction/spec.md`（阈值改为百分比式、删条数门槛、触发口径改回统一规则、L1 不再一落盘就冻结）、`openspec/specs/model-gateway/spec.md`（摘要 profile 不再由压缩设计指定 `max_tokens`）；**归档前置**：这两份基线的顶层小节头原本都是 `## ADDED Requirements`、且都没有 `## Purpose`，openspec 只在 `## Requirements` 下收集 requirement，不改就落不上 delta（实测 `openspec archive` 会 Aborted），两份都已补齐（见 tasks 1.1）；`Docs/context-compression-reference.md` 与 `Docs/rejected-approaches.md`（清掉描述已删上限的表述、更新台账里那条失效指针）；`TODO.md` 顶部「钉死的原始要求」的现状核对段落按实测更新（该节是用户要求钉在那里的判据）。`Docs/TESTING.md` 的真实模型验收要求照旧适用（§5.9）。
- **兼容性**：已有的 `config.json` 不需要改（字段缺省 25）；`summary_nodes` 结构不变；已落盘的旧节点在新逻辑下从"冻结"变为"可以参与合成 L2 摘要"，不改写、不删除。
- **风险**：阈值缺省值取 25%（而不是改动前的 50%）会改变既有测试里手算出来的期望值（已按授权同步更新，属预期）；压缩会比改动前**早得多**地发生（窗口只用了一部分就开始压），细节不可逆地变粗，发出去的原文最多只剩最近不到阈值那么多 —— 这是统一规则的直接结果，频率完全由那个百分比决定，嫌太早或太狠就调大百分比（见 design 的 D4、D8）。
