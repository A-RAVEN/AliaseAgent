## Why

`edit_file` 现在有两个会静默出错的地方，和一个让用户无法核对的地方：

1. **写盘不是原子的**：`sidecar/src/tools.cpp` 的 `write_file` 与 `edit_file` 都用 `std::ofstream(..., std::ios::trunc)` 直接覆写原文件。写到一半进程崩溃或断电，原文件就只剩半截，没有回退。
2. **不看文件是不是自己读到的那一版**：C++ 侧没有任何地方把文件的修改时间或大小记下来（查存在性/是否为目录只有 Windows 的 `GetFileAttributesA` 和其它平台的 `stat`，都没有留存）。模型拿十轮前读到的内容去改，或者用户在编辑器里同时改了同一段，`edit_file` 照样按当前内容匹配、匹配上就写——改错了不会有任何提示。
3. **改了什么，用户看不到**：`edit_file` 只返回 `{"replacements": N}`，卡片上是一句 `Edited <路径> (N replacements)`。用户想知道"到底哪几行被换了"，只能自己打开文件对比。

## What Changes

- **原子写**：`write_file` 与 `edit_file` 的落盘改成"同目录临时文件 → 写入并刷盘 → 改名覆盖目标"，失败时删除临时文件并保持原文件不动。
- **读前校验**：`edit_file` 要求该文件在本进程内被观测过（`read_file` 成功、`write_file` 成功、或此前 `edit_file` 成功三者之一）；未观测过的文件直接拒绝，错误里说明"先用 read_file 读再改"。
- **版本守卫**：观测时记录文件的修改时间与大小；`edit_file` 匹配前先比对，不一致就拒绝并返回 `stale`，提示重新读取。
- **结果补数据**：`edit_file` 成功结果新增 `hunks` 数组，每个元素是一处**实际被替换**的 `{start_line, old_text, new_text}`（行号 1 起、按文件顺序、反映磁盘上真实被替换的字节，不是模型参数里的原文）。
- **卡片出 diff**：展开 `edit_file` 卡片的结果区时，按 `hunks` 渲染"旧行红 / 新行绿"的对比，最多显示 12 行（用户在本次对话的提问中从 8/12/16/不设上限四个选项里选定 12 行，2026-10-18），超出折叠为"还有 N 行未显示"并可点开；折叠态不渲染 diff，仍按现有行为显示一句话结果。`hunks` 因过大被省略时，卡片要写一句可见说明，不能看起来和"没有改动"一样。
- **标题行瘦身**：`edit_file` 与 `write_file` 卡片的标题从整行 `路径=…, edits=[…]` 改成 `工具名(路径)`，`edit_file` 带上 `+N/−M`（折叠态也能一眼看到改了几行）。
- **模型看到行号**：`edit_file` 成功后，模型看到的结果文本从 `Edited <路径> (N replacements)` 扩展为带改动行号；行号清单本身按仓库已有的 8000 字符截断阈值处理（超出时写明共几处、只列前几处，完整内容在卡片上），不新造上限。
- **请求体只带 tool_use 的最小字段**：实时请求目前是把整条工具活动（含 `result`、`resultPreview`）挂进 `assistantBlocks` 再发出的，重放路径只发 `type/id/name/input`。改成实时路径也只发这四项，`hunks` 因此永不进入任何请求体。
- **不计入上下文预算**：`hunks` 会随工具活动落库，但上下文估算（`ContextEstimator` 按 `toolCallsJson` 的字符数折 token）与占用环的原文段统计都不得因它变大，否则一次大编辑会凭空抬高占用率、提前触发压缩。
- **顺带修 `read_file` 的截断标记**：现在只有"默认第一页"会标截断，模型自己传 `limit`/`offset` 时被截掉的部分没有任何标记。改成只要没读到文件末尾就标（复用现有那句带续读参数的提示）。
- **文档同步**：`Docs/user-guide/tools-file.md` 补上"必须先读再改"、"文件被外部改过会被拒绝"、"卡片上的 diff 怎么看"。

## Capabilities

### New Capabilities

（无：本次改的都是已有能力的行为，不新增能力名）

### Modified Capabilities

- `file-edit-tools`：`write_file`/`edit_file` 的落盘改为原子写；`edit_file` 增加读前校验与版本守卫；成功结果新增 `hunks` 字段；新增两个可分辨的错误（未读过、内容已变）。
- `tool-call-result-display`：`edit_file` 卡片在展开态新增 diff 展示与 12 行折叠规则；`edit_file`/`write_file` 卡片的标题行只显示路径，`edit_file` 另带改动行数；模型看到的 `edit_file` 结果文本带改动行号；`hunks` 不计入上下文估算。

## Impact

- **C++ sidecar**：`sidecar/src/tools.cpp`（两个写入点、观测表、版本比对、`hunks` 结果、两个错误）；`sidecar/src/tools.h` 增加测试用清空入口；`sidecar/src/sidecar_api.cpp` 无需改签名（入参出参都是 JSON）。测试落 `sidecar/test/tool_execution_test.cpp`。
- **Dart**：`lib/models/tool_call_activity.dart`（新增可空 `hunks`，序列化向后兼容）、`lib/main.dart`（`edit_file` 结果解析出 `hunks` 与行号文本；sidecar 的错误文本原样透传，不改写）、`lib/ui/tool_call_card.dart`（展开态的 diff 区块与标题行）、`lib/services/context_estimator.dart`（估算时排除 `hunks`）。测试落 `test/unit`、`test/widget`、`test/integration`。
- **持久化**：`hunks` 随工具活动一起存进消息的 `toolCallsJson`；老会话没有该字段必须照常显示。
- **文档**：`Docs/user-guide/tools-file.md`。
- **不改**：`write_file` 不出 diff 卡片（用户在本次对话中决定，2026-10-18）；不加按文件加锁（工具是串行 await 执行的，见 `lib/main.dart` 的工具执行循环）；不做准备阶段的体积进度显示（Anthropic 的 tool_use 参数一次性到齐，没有半截参数可显示）。
