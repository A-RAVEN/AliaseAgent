## Why

AliasAgent 目前只有 `read_file` 和 `list_dir` 两个文件工具——AI 能看但不能改。用户需要 AI 帮助编辑代码、修改 Markdown 文档、创建配置文件等。没有写文件能力，AI 只能"告诉你怎么改"而不能"帮你改"。

参考 Claude Code 的 Edit 工具设计：通过精确字符串匹配实现安全编辑，AI 必须提供原文（`old_text`）和新文本（`new_text`），匹配失败则拒绝编辑。在此基础上增加空白容错匹配和诊断式错误，减少因缩进/行尾符差异导致的频繁编辑失败。

## What Changes

- **新增 `write_file` 工具**: 创建或覆盖文件，AI 提供 path + content
- **新增 `edit_file` 工具**: 精确搜索替换，AI 提供 path + old_text + new_text
  - 三级匹配策略：精确匹配 → 空白归一化匹配 → 诊断式错误
  - 唯一性检查：old_text 匹配多处时拒绝，返回候选位置
  - 诊断信息：匹配失败时返回最相似文本、差异描述、文件元信息（缩进风格、行尾符）
- **增强 `read_file` 工具**: 行号输出（cat -n 格式）、部分读取（offset + limit）、大文件截断（默认 2000 行）
- **Dart 侧**: 工具定义、_executeTool 分支、ToolCallCard 展示编辑结果
- **安全**: 所有路径限制在 workspace 内（复用现有 `resolve()` 逻辑）

## Capabilities

### New Capabilities
- `file-edit-tools`: write_file 和 edit_file 工具，含空白容错匹配和诊断式错误；read_file 增强（行号、部分读取）

### Modified Capabilities
无

## Impact

- **C++ sidecar**: `tools.cpp` 新增 write_file、edit_file 实现，增强 read_file（行号、offset/limit）；`sidecar_api.h/cpp` 新增 FFI 导出
- **Dart FFI bridge**: `ISidecar` 接口新增 `writeFile`/`editFile` abstract methods；`sidecar_bridge.dart` 新增绑定；FakeSidecar 需同步实现
- **Dart UI**: `main.dart` 工具定义 + _executeTool 分支
- **测试**: C++ 单元测试（匹配逻辑）+ Dart FFI 测试 + read_file 格式变更测试更新 + live UI 测试场景
