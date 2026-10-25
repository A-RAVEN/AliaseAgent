## Why

今天这个应用只认文字：用户把截图贴在输入框里没有任何反应，模型也没法自己去看一张图。而 DeepSeek 官方文档（`Docs/DeepSeekAPIDoc.md` §6.4，2026-10-24 抓取）写明 `deepseek-flash` 支持图片输入，图片可以出现在 `user` 消息里（`tool_result` 就住在 user 消息内）；本次探索已实测确认这条通道在真实端点上可用：同一张 512×512 纯红图，模型 `deepseek-flash` 答出「红色」（`usage.input_tokens = 201`），把同一张图塞进 `tool_result` 的 `content` 数组也答出「红色」（`usage.input_tokens = 485`）。

同一次实测还发现一个必须防的坑：`deepseek-v4-pro` **收下图片但不看**——同一张图只比纯文字多 8 个 token，问红色答「蓝色」、问蓝色答「白色」。HTTP 200、不报错、答案错。所以「能不能看图」必须在发请求前有可见判定，不能"发过去就算支持"。

## What Changes

- **用户贴图**：在输入区加一个「粘贴图片」按钮；同时输入行接管 `Ctrl+V`——剪贴板里是图片就贴图，否则按普通文本粘贴。贴到的图作为该条用户消息的附件一起发出。
- **只存路径**（用户明确要求，先这样）：粘贴的图片写成 `~/.aliasagent/attachments/` 下的一个 PNG 文件；消息里**只记录路径**，不存字节、不存 base64。
- **模型自己看图**：新增 `read_image` 工具——模型给一个工作区内的图片路径，拿回「一段文字信封 + 图片本身」两个内容块。
- **请求拼装**：用户消息带图时 `content` 变成 `[text?, image…]`；工具结果带图时 `tool_result.content` 变成 `[{text},{image}]` 数组（实测可用）。
- **数据库**：`messages` 表加 `attachments` 列，schema v6 → v7。
- **能力判定**：新增配置键 `input_modalities`（默认只有 `text`）。模型没声明 `image` 时图片**不发送**，并在消息里留可见标记——禁止静默丢图。
- **界面**：对话里的用户消息显示所贴的图；`read_image` 的工具卡片显示模型看到的那张图。
- **上限前置检查**（数字全部来自 `Docs/DeepSeekAPIDoc.md` §6.4.3）：单张 ≤ 32 MiB、单边 ≤ 8192 像素、一次请求 ≥15 张图时单边降为 ≤ 4096、一次请求的 base64 图片负载 ≤ 48 MiB；超出时从**最旧**的图开始替换成可见的省略说明，不整条失败。
- **预算与压缩**：图片按官方上限 **1024 token/张** 计入上下文估算；图片被压缩摘要吞掉时，摘要里留一句可见的省略说明。
- **文档**：`README.md` 功能索引、`Docs/user-guide/chat.md`（贴图与看图怎么用）、`Docs/user-guide/tools-file.md`（`read_image`）、`Docs/user-guide/configuration.md`（`input_modalities`）同步更新。

**运行环境已有的一处外部改动（不是本 change 的代码）**：`~/.aliasagent/config.json` 里 `agent_types.general.model` 已按用户指令由 `deepseek-v4-pro` 改为 `deepseek-flash`（2026-10-24，改前改后各核过一次：`provider` 仍为 `anthropic`、`max_context_tokens` 仍为 1000000、其余键未动）。本 change 只负责让 `input_modalities` 这个新键有解析路径与文档。

## Capabilities

### New Capabilities

- `image-input`：用户把剪贴板里的图片贴进对话、它如何落盘成 PNG 路径、如何在请求里变成 `image` 内容块、源文件缺失或模型不支持时的可见处置。
- `image-read-tool`：`read_image` 工具——路径解析、格式与尺寸校验、返回的「文字信封 + 图片」两块、失败文案。
- `image-budget`：图片在上下文估算里按多少 token 计（来源：官方 1024 上限）、压缩摘要里如何留下可见的图片省略说明、请求体图片上限的前置检查。

### Modified Capabilities

- `agent-config`：Agent Type 新增可选键 `input_modalities`（默认 `["text"]`），决定图片是否随请求发出。
- `session-persistence`：新增 `attachments` 列与 v6 → v7 迁移。
- `ffi-bridge`：新增两个导出函数——`read_image`（工具用）与 `read_clipboard_image`（取剪贴板图片并落盘）。
- `chat-ui`：用户消息气泡显示附件图片（贴图入口本身归 `image-input`）。
- `tool-call-result-display`：工具卡片能显示图片结果（今天只认文本与编辑差异）。

## Impact

- **C++ sidecar**：`sidecar/src/tools.cpp`（`read_image` 与图片头解析）、新增剪贴板与 PNG 落盘实现、`sidecar/include/sidecar_api.h`（两个新导出）、`sidecar/CMakeLists.txt`（新增源文件与第三方单头文件）、`sidecar/test/`（新用例）。
- **Dart**：`lib/main.dart`（工具定义、`_executeTool`、`_buildApiMessages`、工具结果拼装）、`lib/models/message.dart`、`lib/services/database_service.dart`（v7）、`lib/services/sidecar_bridge.dart`（两个新绑定）、`lib/models/agent_type_config.dart`（`input_modalities`）、`lib/ui/input_bar.dart`、`lib/ui/message_bubble.dart`、`lib/ui/tool_call_card.dart`、`lib/services/context_estimator.dart`、`lib/models/context_breakdown.dart`、`lib/services/compaction/*`（摘要里的省略说明）。
- **数据库**：`messages.attachments TEXT`（JSON 数组，元素只有 `{"path": "..."}`）；迁移只做 `ALTER TABLE ADD COLUMN`，不动既有数据。
- **第三方**：需要 vendor 两个单头文件（`stb_image.h`、`stb_image_write.h`）用于「剪贴板原始位图 → PNG」与「读尺寸/自测解码」，与既有做法一致（`sidecar/third_party/json` 同样是 vendored 单头文件）。
- **不改变**：`write_file` / `edit_file` / 搜索 / 浏览器 / 压缩树结构；不使用 Files API、不实现图片缩放、不引入新的 Dart 包依赖。
- **已知限制（要写进用户文档）**：只记录路径 ⇒ 源文件被改名、移动、覆盖或删除后，历史回放会缺图或送出改过的图；删除会话不会删除 `attachments/` 目录下的文件。
