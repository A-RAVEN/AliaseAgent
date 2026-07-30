## Context

当前文件工具只有 `read_file` 和 `list_dir`（C++ `tools.cpp`），路径限制在 workspace 内（`resolve()` 函数）。AI 能读不能写。

Claude Code 的 Edit 工具证明了一种有效的反幻觉设计：AI 必须提供精确的 `old_text`，匹配失败则拒绝编辑。但实际使用中，AI 经常因为缩进（tabs vs spaces）、行尾符（CRLF vs LF）、尾部空白等差异频繁编辑失败，且错误信息只说"not found"，不告诉 AI 错在哪。

## Goals / Non-Goals

**Goals:**
- AI 能创建、覆盖、精确编辑 workspace 内的文件
- 编辑工具对空白差异（缩进、行尾符、尾部空白）有容错能力
- 编辑失败时返回诊断信息，帮助 AI 一次修好
- 所有操作限制在 workspace 内

**Non-Goals:**
- 不做 undo/redo
- 不做多文件批量编辑
- 不做 GUI diff 展示（第一版用文本摘要）
- 不做文件监听/热重载

## Decisions

### D1: write_file 工具

```
输入: {"path": "relative/path.txt", "content": "file content here"}
输出: {"ok": true, "path": "absolute/path.txt", "bytes_written": 123, "created": true}
      或 {"ok": false, "error": "..."}
```

- 创建不存在的文件（含父目录）或覆盖已有文件
- `created`: true 表示新建文件，false 表示覆盖已有文件（AI 可以据此判断是否意外覆盖）
- 路径通过 `resolve()` 限制在 workspace 内
- 返回写入字节数供 AI 确认

### D2: edit_file 工具 — 三级匹配

```
输入: {"path": "file.dart", "old_text": "...", "new_text": "...", "replace_all": false}
输出: {"ok": true, "replacements": 1}
      或 {"ok": false, "error": "...", "diagnosis": {...}}
```

**前置检查**: `old_text` 不能为空字符串。空字符串 → 立即返回 `{"ok":false, "error":"old_text must not be empty"}`。空字符串在 `std::string::find("")` 中匹配所有位置，会导致无限插入循环损坏文件。

**匹配策略（按优先级）**:

**第一级：精确匹配**
- `old_text` 在文件内容中逐字节匹配
- 匹配 0 次 → 进入第二级
- 匹配 1 次 → 替换，返回成功
- 匹配 >1 次且 `replace_all == false` → 拒绝，返回所有匹配位置（行号）

**第二级：空白归一化匹配**
- 将文件内容和 `old_text` 都做归一化：
  - CRLF → LF
  - Tab → 4 spaces（或检测文件实际缩进）
  - 去除每行尾部空白
- 归一化后匹配唯一 → 替换（在原始文件中定位对应位置），返回成功 + 提示 "matched with whitespace normalization"
- 归一化后匹配 >1 次 → 拒绝，返回所有匹配位置（行号），与 Tier 1 多匹配行为一致
- 归一化后仍不匹配 → 进入第三级

**第三级：诊断式错误**
- 用滑动窗口 + 编辑距离（Levenshtein）找最相似的文本片段
- 返回诊断信息：

```json
{
  "ok": false,
  "error": "old_text not found in file",
  "diagnosis": {
    "file_indent": "4 spaces",
    "file_line_ending": "CRLF",
    "closest_match": {
      "line": 42,
      "actual_text": "    final count = 0;\r\n",
      "your_text": "  final count = 0\n",
      "differences": [
        "indentation: file uses 4 spaces, you used 2",
        "missing ';' at end",
        "line ending: file uses CRLF, you used LF"
      ]
    }
  }
}
```

### D3: 文件元信息检测

edit_file 在匹配前先检测文件特征：
- **缩进风格**: 扫描前 50 行，统计 tab 开头 vs space 开头的行，判断 tabs/spaces 和宽度
- **行尾符**: 检测 `\r\n` vs `\n`
- 这些信息用于第二级归一化和第三级诊断

### D4: 工具定义

```dart
'write_file': {
  'name': 'write_file',
  'description': 'Create or overwrite a file in the workspace. '
      'Use this for creating new files or complete rewrites.',
  'input_schema': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'File path relative to workspace root'},
      'content': {'type': 'string', 'description': 'Complete file content to write'},
    },
    'required': ['path', 'content'],
  },
},
'edit_file': {
  'name': 'edit_file',
  'description': 'Edit a file by replacing exact text. '
      'You MUST read the file first to get the exact old_text. '
      'old_text must match the file content exactly (or with whitespace normalization). '
      'If old_text matches multiple locations, the edit is rejected.',
  'input_schema': {
    'type': 'object',
    'properties': {
      'path': {'type': 'string', 'description': 'File path relative to workspace root'},
      'old_text': {'type': 'string', 'description': 'Exact text to find and replace'},
      'new_text': {'type': 'string', 'description': 'Replacement text'},
      'replace_all': {'type': 'boolean', 'default': false, 'description': 'Replace all occurrences'},
    },
    'required': ['path', 'old_text', 'new_text'],
  },
},
```

工具始终可用（不依赖 search providers），和 read_file/list_dir 同级。

### D5: C++ 实现位置

- `write_file` 和 `edit_file` 实现在 `tools.cpp`（和 read_file/list_dir 一起）
- FFI 导出在 `sidecar_api.h/cpp`
- 字符串匹配和诊断逻辑在 `tools.cpp` 内（不新建文件，保持简单）

### D6: 编辑结果展示

第一版从简：
- write_file: ToolCallCard 显示 "写入 path (N bytes)"
- edit_file: ToolCallCard 显示 "编辑 path (N replacements)"
- 不做 diff 渲染，result 字段包含 old_text → new_text 摘要

### D7: 安全

- 路径限制：复用 `resolve()` 函数，workspace 外路径返回 "Access denied"
- 不限制文件类型（代码、Markdown、配置文件都可以编辑）
- write_file 覆盖前不备份（第一版）
- 二进制/非文本检测：edit_file 拒绝以下情况：
  - 文件前 512 字节含 NUL（排除 UTF-16 等纯文本编码的误判）
  - 文件大小超过 1MB（避免大文件匹配性能问题）
- 已知限制：Windows 上 `resolve()` 使用 `GetFullPathNameA`，不解析 junction/symlink reparse point。恶意 junction 可逃逸 workspace（read_file 已有此问题，write_file 加剧）。此为既有 bug，不在本次变更范围

### D8: read_file 增强 — 行号 + 部分读取

当前 `read_file` 返回整个文件的原始内容，无行号，AI 编辑时容易搞错缩进和位置。

**增强内容**:

**行号输出**: 返回 `cat -n` 格式，每行带 1-indexed 行号前缀：
```
     1	import 'dart:io';
     2	
     3	void main() {
     4	  final count = 0;
     5	}
```

**部分读取**: 新增可选参数 `offset`（起始行，1-indexed）和 `limit`（行数）：
```
输入: {"path": "main.dart", "offset": 100, "limit": 50}
输出: 第 100-149 行（带行号）
```

**大文件截断**: 默认最多返回 2000 行。超出时返回前 2000 行 + 提示：
```
"... (file has 5000 lines, showing 1-2000. Use offset/limit to read more.)"
```

**实现**: 在 C++ `read_file_impl` 中处理。新增参数通过 JSON 传入（`offset`、`limit`），向后兼容（不传则读全文，最多 2000 行）。行号在 C++ 侧格式化，不增加 Dart 侧复杂度。

**边界条件**: offset <= 0 → 返回错误 "offset must be >= 1"。offset > total_lines → 返回空内容 + 提示 "offset exceeds file length"。offset+limit > total_lines → 返回 offset 到文件末尾（不报错，正常截断）。

**向后兼容**: 不传 offset/limit 时行为不变（之前返回整个文件内容；现在改为返回前 2000 行带行号）。这会影响任何断言 `content` 精确内容的测试——需要同步更新。

**工具定义更新**:
```dart
'read_file': {
  'input_schema': {
    'properties': {
      'path': {'type': 'string'},
      'offset': {'type': 'integer', 'description': 'Start line (1-indexed). Default: 1'},
      'limit': {'type': 'integer', 'description': 'Number of lines to read. Default: 2000'},
    },
    'required': ['path'],
  },
}
```

### D9: ISidecar 接口 + FFI 绑定

`write_file` 和 `edit_file` 需要在以下层添加绑定：

```
ISidecar (abstract interface)
  → + String writeFile(String requestJson);
  → + String editFile(String requestJson);

SidecarBridge (production)
  → + FFI lookup: Pointer<Utf8> Function(Pointer<Utf8>) for write_file, edit_file
  → + 同步调用（不跨 isolate，文件 I/O 足够快）

FakeSidecar (test double)
  → + 对应实现（内存文件系统或错误注入）
```

注意：read_file 当前签名是 `String readFile(String path)`，只接受 path 字符串。新增 offset/limit 后，需改为 `String readFile(String requestJson)` 接受 JSON，或保持签名不变而在 `_executeTool` 中做 JSON 拼接。**决定采用保持签名不变 + Dart 侧 JSON 拼接的方式**（改动最小）。

## Risks / Trade-offs

- [AI 覆盖重要文件] write_file 可覆盖任何 workspace 内文件 → 工具描述提醒 AI 谨慎使用；用户应在版本控制下工作
- [编辑距离计算性能] 大文件的 Levenshtein 匹配可能慢 → 限制滑动窗口大小（±5 行），不做全文搜索；1MB 以上文件拒绝 edit_file
- [空白归一化误匹配] 归一化后不同代码段可能变得相同 → 唯一性检查保底，返回候选行号
- [CRLF 复杂性] Windows 文件 CRLF 和 AI 生成的 LF 不一致 → 归一化层处理
- [read_file 格式变更] 行号输出会破坏现有测试的精确 content 断言 → tasks 中包含测试更新
- [sync vs async] write_file/edit_file 是同步 I/O（不需要 worker isolate），与 web_search/web_fetch 的 async 模式不同 → 需要同时添加 sync 和 async 的 FFI 绑定
- [Windows junction] `resolve()` 使用 `GetFullPathNameA` 不解析 reparse point → junction 可逃逸 workspace → 既有 bug，不在本次变更范围
