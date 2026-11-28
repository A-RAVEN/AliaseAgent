# 常见现象与排查

## 这是什么

一份「看到这个现象，它是什么意思，下一步做什么」的对照表。**表里每一条都是代码里确实会产生的东西**（错误文案可以从代码里原文核到），不是猜测。

## 日志在哪

```
%USERPROFILE%\.aliasagent\logs\sidecar.log
```

Windows 上就是 `C:\Users\你的名字\.aliasagent\logs\sidecar.log`。应用自己打印的提示带 `[AliasAgent]` 前缀；模型请求失败时，日志里能查到 HTTP 状态码和服务端返回的原文。

数据库、配置也都在同一个目录（`~/.aliasagent/`）下。

## 对照表

| 你看到的 | 它是什么 | 下一步 |
|---|---|---|
| 启动后整屏 `Configuration Error`，下面有 `Invalid JSON in <路径>: ...` | 配置文件不是合法 JSON | 按提示的路径打开文件修好语法，重启应用。详见 [配置](configuration.md) |
| 启动后整屏 `Configuration Error`，下面有 `Unexpected data structure in <路径>: ...` | JSON 合法但结构不对：少了 `api_key`、少了 `general`、某个字段类型不对 | 对照 [配置](configuration.md) 里的完整示例补齐 |
| 又弹一次欢迎对话框 | 没有配置文件，或者 `general` 里没有可用的 `max_context_tokens` | 按对话框填，或直接改文件补上这个键 |
| 对话框里红字 `Please enter an API key` / `Please enter a valid max context token count (a positive integer)` | 首启对话框的输入不合法 | 填 key；token 数填正整数 |
| 对话里一条以 `Error: ` 开头的回复 | 这一轮请求失败，冒号后面是原因 | 按原因处理：key 无效、欠费、服务地址写错、网络不通。具体 HTTP 状态在日志里 |
| 回复里是 `Provider "xxx" not found.` | agent 里写的 `provider` 在 `providers` 里找不到同名的项 | 两边名字改成一致。详见 [配置](configuration.md) |
| 回复里是 `No agent type configured.` | 配置里没有名字叫 `general` 的 agent | 加上 `general` |
| 工具卡片状态 `Error`，结果是 `Access denied: path outside workspace` / `path traversal not allowed (..)` / `absolute path not allowed` | 模型想碰当前工作区以外的文件，被拒了 | 这是**故意拦的**；把你的要求改成当前工作路径下的相对路径。工作区**缺省**是用户主目录，单聊 / 群可以改到别的目录（见 [文件工具](tools-file.md)） |
| 在文件夹选择框里点「选择此目录」后框内提示「不存在」/「不可用」 | 该目录不可用（被删了、没有访问权限，或不是目录） | 在框里换一个目录再确认（框不会自动关，已保存的路径也没变）；路径是默认根 + 软围栏，不是沙箱，`run_command` 仍以你的权限执行、不可撤销，详见 [web 核心](web-core-shim.md) |
| 在文件夹选择框的地址栏输入路径后回车，框内提示「读取目录失败：…不存在 / 不是目录 / 绝对路径」 | 地址栏输入的路径不可用（打错、相对路径、指向文件）。核心拒绝后**不会跳转** | 改对再回车，或直接点选目录；框内列表与地址栏仍停在原文件夹，已保存的工作路径不受影响 |
| 工具卡片结果里有 `File too large for edit_file (>1MB)` / `Cannot edit binary or non-text file` | 这个文件超出 `edit_file` 的处理范围 | 让它整份重写（`write_file`），或者你自己改 |
| 工具卡片结果是 `No search providers configured` | 一家搜索服务都没配，模型却在搜 | 在配置里加 `zhipuai` 或 `kimi` 的 `api_key`。详见 [联网工具](tools-web.md) |
| 工具卡片结果是 `Fetch failed: internal address not allowed` | 想抓本机或内网地址，被拒了 | 这是**故意拦的**；换成公网地址 |
| 模型完全不知道有浏览器工具 | 启动探测没通过（缺 Playwright / 没有可用的 Edge 或 Chromium） | 装好后重启应用。详见 [浏览器工具](tools-browser.md) |
| 弹出一个浏览器窗口自己在动 | 模型在用浏览器工具，**设计如此** | 不用管，也别手动关那个窗口（关了下一步会重开） |
| 对话越来越短、前面出现 `## 更早上下文(压缩xN,非用户发言)` 这样的开头 | 长对话被压缩了，老内容换成了摘要 | 正常行为；想少压就调大 `compaction_threshold_percent`。详见 [上下文压缩](context-compaction.md) |
| 日志里一行 `compaction_threshold_percent=... is absent or not an integer in 1..100 — using the default 25% ...` | 这个键的值不合法，按 25% 走了 | 改成 1 到 100 的整数 |
| 日志里 `browser_available probe failed: ...` | 启动时探测浏览器环境时抛了异常 | 按后面的异常信息查；四个浏览器工具这次不会出现 |
| 日志里 `Search infra init failed` / `Failed to parse search config: ...` | `search` 这一块的配置有问题 | 对照 [配置](configuration.md) 检查 `search` 段 |

## 还想更深入时

- **模型这一步到底看到了什么** → 切到「真实上下文」那一屏看，见 [真实上下文视图](real-context-view.md)。
- **想知道为什么它开始压缩了** → 见 [上下文压缩](context-compaction.md) 里的阈值算法。
- **开发相关的排查**（崩溃、C++ 侧车、ASan 构建）不在本手册范围内，见仓库里的 `DEBUGGING.md`。
