# context-compaction Specification

## MODIFIED Requirements

### Requirement: Near-zone oversized tool_result body elision
For a recently-kept (verbatim) tool round whose tool_result content is extremely large, the system SHALL be permitted to elide the oversized BODY to a truncation marker plus a refetch record (path/byte/line range) while preserving the tool_use block, the tool_result placement, and the tool round structure. This is a documented near-zone exception to full-body replay; it never folds or splits the round, nor does it break tool_use/tool_result pairing.

**再取记录的形态要统一**（并入 `truncation-visibility` 的总规则）：这条要求里的 "refetch record" 之前只按 `path` 拼，而只在 `url` 上成立的结果（例如 `web_fetch`）拼出来是空的。再取记录 SHALL 按可用输入拼：有 `path` 用 `path`；没有 `path` 而有 `url` 时用 `url`（形如 `refetch via web_fetch "<网址>"`）；两者都没有时 SHALL 写明"无法自动再取，请重新给出地址"，SHALL NOT 留空。标记 SHALL 同时说清略去了多少（字符数或行数区间）。

#### Scenario: Oversized near tool_result body elided

- **WHEN** a kept (verbatim) near tool round has a tool_result body exceeding a size threshold
- **THEN** its body is replaced by a truncation marker + refetch record, while the tool_use block and the round structure remain intact and unchanged

#### Scenario: Round structure preserved on elision

- **WHEN** an oversized near tool_result body is elided
- **THEN** no tool_use/tool_result pair is folded or split, and the message remains valid alternation

#### Scenario: 只在 url 上成立的结果也有再取入口

- **WHEN** 被裁掉正文的那次工具调用没有 `path` 参数、只有 `url`（例如 `web_fetch`）
- **THEN** 标记里的再取记录 SHALL 用那个 `url` 拼出可照抄的再取动作；把 `url` 分支去掉 SHALL 让对应用例失败

#### Scenario: 两者都没有时说清取不回

- **WHEN** 被裁掉正文的那次工具调用既没有 `path` 也没有 `url`
- **THEN** 标记 SHALL 写明无法自动再取，SHALL NOT 留一段空的再取记录
