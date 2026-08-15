# Ripgrep 官方文档（本地整理）

> **抓取时间**: 2026-08-10（WebSearch + WebFetch，主循环维护）
> **实测确认**: 2026-08-15（add-file-tools apply 阶段，用 tools/rg.exe 15.2.0 Windows 版实测回填 —— 见各节 [实测] 标注）
> **来源 URL**: https://man.archlinux.org/man/rg.1.en （ripgrep 15.2.0, Arch Linux 手册）
> 本文档仅收录已验证的 ripgrep 外部事实，供 Workflow 审查 agent 引用（禁止互联网，外部真实性唯一依据本地 Docs/*.md）。

## 1. `--json` 输出格式

- 官方原文: "Enable printing results in a JSON Lines format."
- JSON Lines 格式，共 5 种消息类型: `begin`, `end`, `match`, `context`, `summary`
  - `begin`: "A message that indicates a file is being searched and contains at least one match."
  - `end`: "A message the indicates a file is done being searched."（含该文件摘要统计）
  - `match`: "A message that indicates a match was found. This includes the text and offsets of the match."
  - `context`: "A message that indicates a contextual line was found."
  - `summary`: "The final message emitted by ripgrep that contains summary statistics about the search across all files."
- 编码: 路径和文件内容不保证是合法 UTF-8，而 JSON 必须是 Unicode 可表示的，因此每个数据元素以对象发出，含 `text` 键（合法 UTF-8 字符串）或 `bytes` 键（base64）
- "enabling JSON output will always implicitly and unconditionally enable --stats."
- 标准输出 flags（`-o`, `--heading`, `-r`, `-M` 等）在 `--json` 下无效果
- **`--json` 与 `--files`、`-l/--files-with-matches`、`--files-without-match`、`-c/--count`、`--count-matches` 组合会产生错误**

### 1.1 `--json` match 消息字段名 schema [实测确认 2026-08-15]

用 `tools/rg.exe 15.2.0` 实测确认（此前未验证，现已验证，可作审查依据）：

```json
{"type":"match","data":{
  "path":{"text":"src/a.txt"},
  "lines":{"text":"alpha MATCHWORD\n"},
  "line_number":1,
  "absolute_offset":0,
  "submatches":[{"match":{"text":"MATCHWORD"},"start":6,"end":15}]
}}
```

- `data.path.text` — 文件路径（合法 UTF-8 时用 `text` 键）
- `data.path.bytes` — 路径为非 UTF-8 时用 `bytes`（base64）
- `data.lines.text` — 匹配行内容（合法 UTF-8 时）
- `data.lines.bytes` — 行内容为非 UTF-8 时用 `bytes`（base64）；实测含 `\xff\xfe` 的行输出 `"lines":{"bytes":"...base64..."}`
- `data.line_number` — 1 起始行号（整数）
- `data.submatches[].match.text` / `start` / `end` — 匹配子串与字节偏移
- `data.absolute_offset` — 文件内字节偏移
- `end` 消息含 `data.path` + `data.stats`（searches/bytes_searched/matched_lines/matches 等）
- `summary` 消息含 `data.elapsed_total` + `data.stats`（全局统计）

## 2. `-g/--glob` glob 语义

- 官方原文: "Globbing rules match .gitignore globs."
- "This always overrides any other ignore logic."
- "Precede a glob with a ! to exclude it."
- "If multiple globs match a file or directory, the glob given later in the command line takes precedence."
- "When this flag is set, every file and directory is applied to it to test for a match."
- 反例（关于深度）: "then `-g foo` is incorrect because `foo/bar` does not match the glob `foo`. Instead, you should use `-g 'foo/**'`."
- 扩展语法: 支持 alternatives —— "globs support specifying alternatives: `-g 'ab{c,d}*'` is equivalent to `-g abc -g abd`."

### 2.1 `*` / `?` / `**` 精确匹配语义 [实测确认 2026-08-15]

此前标注"未验证"（仅"match .gitignore globs"推论），2026-08-15 实测确认：

- `*` 匹配**单个路径段内**的任意字符（不跨 `/`）：`-g "src/*.txt"` 匹配 `src/s1.txt`，**不**匹配 `src/sub/s2.txt`
- `?` 匹配**恰好一个**字符：`-g "src/?.txt"` 匹配 `src/a.txt`（不匹配 `src/ab.txt`）
- `**` 匹配**跨目录**：`-g "src/**/*.txt"` 同时匹配 `src/a.txt` 与 `src/sub/b.txt`
- **无斜杠 pattern 匹配任意深度**（gitignore 风格）：`-g "*.txt"` 同时匹配 `root.txt` 与 `a/b/deep.txt`
- `!` 取反生效：`-g "!**/*.log"` 排除所有 `.log` 文件

## 3. `--files` flag

- 官方原文: "Print each file that would be searched without actually performing the search."
- "This is useful to determine whether a particular file is being searched or not."

## 4. EXIT STATUS（退出码）

- 官方原文:
  - "If ripgrep finds a match, then the exit status of the program is 0."
  - "If no match could be found, then the exit status is 1."
  - "If an error occurred, then the exit status is always 2 unless ripgrep was run with the -q/--quiet flag and a match was found."
  - "This is true for both catastrophic errors (e.g., a regex syntax error) and for soft errors (e.g., unable to read a file)."
- 总结:
  - `0` = 至少一个匹配且无错误（除非 -q）
  - `1` = 无匹配且无错误
  - `2` = 发生错误（含正则语法错误、无法读取文件）

## 5. `-i/--ignore-case`

- 官方原文: "When this flag is provided, all patterns will be searched case insensitively."
- "The case insensitivity rules used by ripgrep's default regex engine conform to Unicode's 'simple' case folding rules."
- "This flag overrides -s/--case-sensitive and -S/--smart-case."

## 6. `-m/--max-count`

- 官方原文: "Limit the number of matching lines per file searched to NUM."
- "it's possible for more matches than the maximum to be printed if contextual lines contain a match."
- "Note that 0 is a legal value but not likely to be useful."
- 多行模式（-U）下跨行匹配计一次；一行多匹配计一次

## 7. `--` 参数分隔符

- 官方原文: "You can also use the special `--` delimiter to indicate that no more flags will be provided."
- 示例: `rg -- -foo` 等价于 `rg -e -foo`
- 补充: "To match a pattern beginning with a dash, use the -e/--regexp option."

## 8. `.gitignore` 处理

- 官方原文: "ripgrep will attempt to respect your gitignore rules as faithfully as possible."
- 覆盖范围: 全局规则（`$HOME/.config/git/ignore`）、相关 `.gitignore` 文件（同一 git 仓库内父目录的）、本地规则（`.git/info/exclude`）
- **重要限制**: "ripgrep will only respect filter rules from source control ignore files when ripgrep detects that the search is executed inside a source control repository; `--no-require-git` relaxes that restriction." —— 默认只在检测到 git 仓库内才尊重 .gitignore
- 非 git 规则来源: `.ignore`、`.rgignore`、`--ignore-file` 指定文件（始终生效）
- 优先级（低→高）: `--ignore-file` 路径 < 全局 gitignore < `.git/info/exclude` < `.gitignore` < `.ignore` < `.rgignore`
- 注意: "ripgrep and git can disagree, e.g., a git-tracked file that is ignored via .gitignore would still not be searched by ripgrep; the suggested workaround is `git grep`."

## 9. 已验证 flags 汇总

| flag | 状态 | 说明 |
| --- | --- | --- |
| `--json` | ✅ 已验证 | JSON Lines，5 种消息类型；与 --files 组合报错 |
| `--files` | ✅ 已验证 | 打印将搜索的文件 |
| `-g/--glob` | ✅ 已验证 | gitignore 风格；! 取反；alternatives 扩展 |
| `-n/--line-number` | ✅ 已验证（外部来源） | 默认 TTY 下开启；JSON 下 -n 无额外效果 |
| `-i/--ignore-case` | ✅ 已验证 | Unicode simple case folding |
| `-m/--max-count` | ✅ 已验证 | 每文件最大匹配行数 |
| `--` | ✅ 已验证 | 结束 flag 解析 |
| 退出码 0/1/2 | ✅ 已验证 | 0=有匹配，1=无匹配，2=错误（含正则错误） |
| `-e/--regexp` | ✅ 已验证 | 显式指定 pattern（可匹配 - 开头） |
| `--no-require-git` | ✅ 已验证 | 无 git 仓库也尊重 source-control ignore 文件 |

## 9.1 实测确认的行为（2026-08-15，rg 15.2.0 Windows）

以下行为此前未验证，已用 `tools/rg.exe` 实测确认（可作审查依据）：

- **二进制文件跳过**：目录递归搜索时，含 NUL 字节的文件被跳过（不参与匹配）。`rg --json "MATCHWORD" src/` 的 match 中不出现 `bin.dat`。**但显式指定单个文件路径时会被搜索**（`rg --json "MATCHWORD" src/bin.dat` 会报告 match，NUL 以 ` ` 转义进 `lines.text`）——本 change 的 grep_file 使用目录递归，故依赖"递归跳过二进制"行为
- **`.git/` 自动跳过**：`rg --files` 不列出 `.git/` 下的文件
- **输出路径形态**：搜索 root 以绝对路径参数传入时，输出路径形如 `<root前向斜杠形式>\<文件部分反斜杠>`（混合分隔符——root 部分保持入参形态，文件部分用 OS 原生分隔符）；CWD 相对搜索时形如 `.\relative\path`（`.\` 前缀 + 反斜杠）。去根化须同时处理两种分隔符

## 10. 未验证项（不得采纳）

- "rg 1.x 全版本支持这些 flags"——未验证
- "rg 单文件二进制 ~2MB"——未验证
- SIMD/并行性能断言——未验证
- 本 change 实测确认的版本为 15.2.0 Windows x86_64；其他平台/版本的行为以本 change 实测为准
