## Why

Agent 的文件工具集与主流 agent（Claude Code）存在三处能力差距，导致 agent 在工程任务中"找不到文件、搜不了内容、一次只能改一处"：`list_dir` 单层列举无法支撑大目录探索；没有任何内容搜索工具，找符号定义/引用只能逐个 `read_file` 碰运气；`edit_file` 一次只能替换一处，多改动需要多轮 tool_loop，慢且费 token。

## What Changes

- **BREAKING**: `edit_file` 重构为批量编辑接口——`old_text/new_text/replace_all` 顶层字段移除，改为 `edits` 数组（1..N 个 `{old_text, new_text, replace_all?}` 替换对）。全部替换在原始内容上验证唯一匹配，任一失败则整个请求失败零改动；**任一替换对的 `old_text` 为空串立即拒绝**（防死循环）；应用采用倒序策略避免位置偏移；重叠命中拒绝。本项目为新项目，无历史数据兼容负担（数据库中旧会话记录的 tool_use 块为历史 content 块，回灌 API 时不重新执行，无需迁移）。
- **新增 `glob_file` 工具**：按 glob 模式（`*`、`**`、`?`）在 workspace 内递归查找文件，返回相对路径列表。（`*`/`**`/`?` 精确匹配语义未验证——ripgrepDoc 仅记载 gitignore 风格与 `!` 取反/alternatives，实现后以实测为准）
- **新增 `grep_file` 工具**：在 workspace 内按正则搜索文件内容，返回 `path:line:text` 匹配列表（行号基数与 `--json` 字段名 schema 未验证），支持 glob 过滤、大小写开关、max_results 上限（默认 100）。
- `glob_file` 与 `grep_file` 基于 **ripgrep 子进程**实现，复用 `web_fetch` 的 crawl4ai 子进程骨架（CreateProcess + Job Object + 管道轮询 + 超时终止）；rg.exe 不存在时返回明确错误。**外部真实性说明**：本 change 依赖的 rg 行为（`--json`/`--files`/`-g`/`--no-require-git`、退出码 0/1/2、gitignore 处理、`--` 分隔符）已抓取官方 man page 整理入 `Docs/ripgrepDoc.md`（2026-08-10）；SIMD/并行性能、二进制自动跳过、`.git` 自动跳过、单文件体积等为描述性表述，**未验证**，不作为验收依据。
- workspace 沙箱约束不变：所有搜索/编辑仍在 `check_path` 限定范围内；搜索 root 恒为 workspace 根（无 root 入参）。
- **数值参数**（design/spec/tasks 一致）：`edits` 数组上限 100；`grep_file` max_results 默认 100、`glob_file` max_results 默认 200；子进程超时 30s；rg `-m` 取 max_results 的 4 倍放宽值（防首文件独占偏置）。

## Capabilities

### New Capabilities

- `file-search`: glob 模式文件查找 + 正则内容搜索（`glob_file` / `grep_file`），覆盖 rg 子进程执行、输出解析、限制与错误处理

### Modified Capabilities

- `file-edit-tools`: `edit_file` 从单替换接口改为 `edits` 批量数组接口（BREAKING），匹配/拒绝/回滚语义重写

## Impact

- `sidecar/src/tools.cpp`：`edit_file` 重写（edits 数组解析、全部验证、倒序应用）；新增 `glob_file`/`grep_file`（子进程执行 + rg 输出解析）
- `sidecar/src/tools.h`、`sidecar/src/sidecar_api.cpp`：新增 FFI 导出（静态缓冲模式）
- `sidecar/src/web_fetch.cpp`：抽提子进程执行骨架供 rg 复用
- `lib/main.dart`：tool defs 更新（edit_file 新 schema + 两个新工具定义）
- `lib/services/sidecar_bridge.dart`：新增 `globFile`/`grepFile` 同步调用
- 测试：C++ 单测（edit 批量语义、glob 匹配、grep 输出）、Dart 测试（FakeSidecar + 新工具）、live 测试（AI 自然生成新工具调用）
- 依赖：**ripgrep 二进制**随应用分发（`tools/rg.exe`；Linux/macOS 由包管理器安装）；rg 缺失时工具返回安装指引（不自动下载）。单文件体积 ~2MB 为描述性表述，未验证
- specs：delta specs 位于 `openspec/changes/add-file-tools/specs/`（`file-edit-tools/` MODIFIED、`file-search/` ADDED），归档时同步进 `openspec/specs/`（`file-edit-tools/` 追加、新建 `file-search/spec.md`）
- Docs：新增 `Docs/ripgrepDoc.md`（抓取自官方 man page，2026-08-10）供审查引用
