## Context

AliasAgent 的对话请求由 Dart 拼好后整段交给 C++ sidecar 发出去（`lib/main.dart` 的 `_buildApiMessages` → `messages_json` → `sidecar_api.h` 的 `send_message`）。今天这条链路上**没有任何地方能放图片**：

- `lib/models/message.dart` 的 `content` 是 `String`，数据库 `messages.content` 是 `TEXT`；
- `_buildApiMessages` 给每条消息固定发一个 `{'type': 'text'}` 块；
- 工具结果只认 `result['content']` 字符串；
- `lib/ui/message_bubble.dart` 只渲染 `Text` / `MarkdownBody`，`lib/ui/input_bar.dart` 只有输入框和发送按钮。

外部事实（全部有本地出处，见 `Docs/DeepSeekAPIDoc.md` §6.4，2026-10-24 抓取）：

- 支持格式 JPEG / PNG / GIF / WebP，**格式由文件实际内容判断**，不看扩展名或声明的 MIME；
- Anthropic 兼容端点用 `image` 块，`source.type` 为 `base64` 时需 `media_type`；
- **图片只能出现在 `user` 消息里**，`system` / `assistant` 消息带图返回 400；`tool_result` 住在 user 消息的 `content` 数组里，所以工具结果带图是合法的；
- 限制：单张 ≤ 32 MiB（base64 口径）、单边 ≤ 8192 像素（一次请求 ≥15 张图时降为 4096）、一次请求图片总量 ≤ 64 MiB（不含 `file_id` 图）、一次请求 ≤ 600 张；
- 每张图进模型前会被服务端自动缩放（小于约 544×544 的图会被放大，更大的缩到总像素约等于 1300×1300），**每张图 token 上限 1024**。

实测（2026-10-24，同一把 key、同一个端点、同一张 512×512 纯色 PNG）：

| 场景 | 模型 | `input_tokens` | 答案 |
| --- | --- | --- | --- |
| 图在 user 消息里 | `deepseek-flash` | 201 | 红色 ✅ |
| 图在 `tool_result.content` 数组里 | `deepseek-flash` | 485 | 红色 ✅ |
| 图在 user 消息里 | `deepseek-v4-pro` | 22（纯文字对照 14） | 蓝色 ❌ |
| 图在 `tool_result.content` 数组里 | `deepseek-v4-pro` | 312 | 自称看到「Unsupported Image」 |

结论：通道可用，但**模型选错会静默失败**，这正是本设计要一条能力判定兜住它的原因。上表全部读数（含两次 `tool_result` 与 `deepseek-v4-pro` 的三次对照）已逐条记入 `Docs/DeepSeekAPIDoc.md` §6.2 的「实测校准」表。

## Goals / Non-Goals

**Goals:**

1. 用户能把剪贴板里的图贴进对话，图跟着这条用户消息一起发出去。
2. 模型能通过 `read_image` 工具自己看一张工作区里的图。
3. 图和文字走同一条链路：落盘、持久化、回放、压缩、token 估算都不特殊对待。
4. 任何"图没发出去 / 图被省略 / 图丢了"的情形都**在界面和请求里留下可见说明**，不静默降级。
5. 所有数量上限都能指到 `Docs/DeepSeekAPIDoc.md` §6.4，不发明新数字。

**Non-Goals:**

- 不做图片缩放、裁切、转码（除"剪贴板位图 → PNG"这一次编码）。
- 不用 Files API（`source.type: "file"`）。
- 不做文件选择对话框（这一版只有剪贴板入口）。
- 不支持 GIF 动图逐帧、不做 OCR、不做图像编辑。
- 不改 `write_file` / `edit_file` / 搜索 / 浏览器 / 压缩树结构。
- 不引入新的 Dart 包依赖。

## Decisions

### D1 历史只存路径（用户决定）

消息里记录 `{"path": "<绝对路径>"}`，不存字节、不存 `media_type` / 宽高 / 字节数。

**同一口径管到工具活动**：`messages.tool_calls` 里那条工具调用的 `image` 字段也只能写 `{"path": "…"}`（`tool_calls` 就是 `messages` 表的一列，见 D10）。卡片要显示的宽高 / 类型 / 字节数，从两处现取：`read_image` 已经写进 `result` 的文字信封（`image/png image, 800x600 px, 12345 bytes`）能解析出来就直接用，解析不到再读一次文件头。**不另存一份元数据**，否则"库里说 800×600、磁盘上是 1600×1200"这种谎话就没人能发现。

**理由**：用户明确要求"历史先只存路径"；且存了宽高就会在源文件被换掉之后撒谎。

**代价（必须写进用户文档）**：源文件被改名 / 移动 / 覆盖 / 删除后，回放会缺图或送出改过的图。缺失时该图被替换成可见文本 `[图片已丢失：<path>]`，不静默跳过。

**备选（被否）**：按内容哈希拷贝进 `~/.aliasagent/attachments/objects/`（DSH 的做法）——能保证历史不变，但用户明确说"先只存路径"，且要额外实现归一化与去重。

### D2 剪贴板取图与 PNG 落盘都在 C++ sidecar 里

新增导出 `read_clipboard_image(const char* dest_dir_json)`：

1. `OpenClipboard` → 依次试 `CF_PNG`（Windows 上 `RegisterClipboardFormatW("PNG")` 注册的格式，Chrome/Edge 复制图片时会给）、`CF_DIBV5`、`CF_DIB`；
2. `CF_PNG` 命中就直接把字节写成 `.png`（不需要编码器）；
3. 只有 `CF_DIB*` 命中时，把自下而上的 BGRA 位图翻成自上而下、去 padding，用 `stbi_write_png` 编码成 PNG；
4. 写到 `<dest_dir>/paste-<yyyyMMdd-HHmmss-SSS>-<序号>.png`，返回 `{"ok":true,"path":"…","width":W,"height":H,"bytes":N,"media_type":"image/png"}`；失败返回 `{"ok":false,"error":"…"}`。

**理由**：Dart 侧读剪贴板图片没有官方 API（`Clipboard.getData` 只支持文本），而 sidecar 已经是本项目的 Win32 落点（`tools.cpp`、`browser.cpp` 都在调 Win32）。放这里不新增 Dart 依赖，且能用 `sidecar/test` 覆盖。

**备选（被否）**：Dart 侧用平台通道自己开剪贴板——要写两份平台代码；把原始位图 base64 传回 Dart 再由 Flutter 编码 PNG——一张 1920×1080 的截图原始位图 8.3 MB，base64 后 11 MB 挤过 FFI 字符串，代价过大。

**第三方**：vendor `stb_image.h` 与 `stb_image_write.h`（public domain / MIT 双许可的单头文件）到 `sidecar/third_party/stb/`，与既有 `sidecar/third_party/json` 同一做法。`stb_image` 只用来读尺寸（`stbi_info`，不解像素）与测试里回读刚写的 PNG；`stb_image_write` 只用来编码 PNG。

### D3 图片尺寸与格式一律"看字节"，不看扩展名

`read_image` 与粘贴两条路径共用一套判定：

- 先按扩展名筛一遍（`.png/.jpg/.jpeg/.webp/.gif`），扩展名不在表里直接报错（`Not an image: …`）；
- 再看文件头魔数确认真实格式，与扩展名声明的格式不一致时报错（`Image type mismatch: …`）；
- PNG/JPEG/GIF 的宽高用 `stbi_info` 取；**WebP 手写 RIFF 头解析**（`stb_image` 不支持 WebP，`RIFF....WEBP` 之后按 `VP8X` / `VP8 ` / `VP8L` 三种块头取宽高），约 40 行。

**理由**：官方明写"格式由文件实际内容判断，而非文件名或声明的 MIME 类型"；照它的判定走，错误才会在本地就出现，而不是等模型给出莫名其妙的回答。

### D4 能力判定用配置键 `input_modalities`，默认只有 `text`

`AgentTypeConfig` 新增 `inputModalities`（JSON 键 `input_modalities`，字符串数组，元素只认 `text` / `image`，非法值或缺失一律回落 `["text"]`）。

- 请求拼装时：`input_modalities` 不含 `image` ⇒ 每个 `image` 块被替换成一段文字 `[图片未发送：当前模型 <model> 未声明图片输入（input_modalities 不含 image）；图片路径：<path>]`；
- 界面：该消息仍显示缩略图，并在下面加一行提示「模型未声明图片输入，本次没有发送图片」；
- `read_image` 工具：Dart 在分发前先查 `input_modalities`，不含 `image` 时**直接返回错误**、不去调 sidecar —— 模型看不见图的时候让它读文件只会白烧一轮请求。

**理由**：实测证明"模型不支持"不会报错，只会答错。默认 `["text"]` 是**安全方向**（宁可少发并说明，也不静默发出去）。默认值的出处：DeepSeek Harness 的 `dsh-llm-deepseek` 包里，`catalogModelInfo` 给模型的 `inputModalities` 用的缺省就是 `["text"]`（`dsh-llm-deepseek/lib/index.js`：`inputModalities: model.inputModalities ?? ["text"]`；`dsh-llm` 通用类型里"缺省"的含义是"未知"，两者取值一致），本项目采用同一缺省，并在 `Docs/user-guide/configuration.md` 的配置键表里写清。

**代价**：升级后不配这个键就贴不了图。所以本 change 的收尾任务里包含"把 `input_modalities` 写进用户自己的 `~/.aliasagent/config.json` 并实测一条贴图消息"，且 setup 对话框写出的默认配置里也带上这个键。

**备选（被否）**：默认 `["text","image"]`——对 `deepseek-v4-pro` 这种"收图不看图"的模型就是静默错误；按模型名硬编码能力表——模型名可变，等于编造。

### D5 不做缩放，只做上限检查

客户端不缩小、不放大：官方明说服务端会自动把图缩到总像素约 1300×1300，客户端再缩只会更糊且省不下 token（小于 544×544 的图还会被服务端放大回来）。

前置检查（数字全部来自官方 §6.4.3）：

| 检查 | 数值 | 官方出处 | 触发时的处置 |
| --- | --- | --- | --- |
| 单张字节数 | ≤ 33554432（32 MiB） | §6.4.3「单张图片最大大小（base64 / 外部 URL）」 | 该图不发送，替换为可见文本 |
| 单边像素 | ≤ 8192 | §6.4.3「图片最大尺寸」 | 同上 |
| 一次请求图片张数 ≥ 15 | 单边降为 ≤ 4096 | §6.4.3 同一行后半句 | 超限的那张替换为可见文本，其余照发 |
| 一次请求的 base64 图片负载 | ≤ 50331648（48 MiB） | §6.4.3「请求体大小 48 MiB」+ §6.4.1「编码后的数据会计入 **48 MiB** 请求体大小限制」 | 从**最旧**的图开始依次替换成可见文本，直到满足 |
| 一次请求图片原始总字节 | ≤ 67108864（64 MiB） | §6.4.3「单个请求图片总大小」 | 永远先被上一条拦住：base64 后涨 4/3，48 MiB 负载对应原始 ≤ 36 MiB（50331648 × 3 ÷ 4 = 37748736）。这一行保留作对照，写明它在本项目里不会先撞线 |

**两条图片路径（用户贴图、`read_image`）用的是同一套检查**：

- `read_image` 在 C++ 里先查前两条，好处是错误直接落在工具卡片上（早失败）；
- Dart 拼请求时对**每一张**图再查全部五条（贴图路径没有 C++ 检查，且 `read_image` 的结果也会进请求）——这一层是兜底，不能省。

最后两条"从最旧的开始丢"沿用 DSH 的做法（`dsh-compaction-image-offload`：`offloadOldestImages` 选最老的若干处），保证同样的历史每次投影结果一致。

### D6 图片在请求里的样子

用户消息（`_buildApiMessages`）：

```json
{"role":"user","content":[
  {"type":"text","text":"这里的 spacing 怎么调"},
  {"type":"text","text":"[图片 1：image/png，800x600px，123456 字节，路径：C:\\Users\\…\\paste-20261024-101500-1.png]"},
  {"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0…"}}
]}
```

工具结果（`tool_result.content` 变数组）：

```json
{"type":"tool_result","tool_use_id":"toolu_…","content":[
  {"type":"text","text":"<path>lib/a.png</path>\n<type>image</type>\n<content>\nimage/png image, 800x600 px, 12345 bytes\n</content>"},
  {"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw0…"}}
]}
```

两条都照官方 §6.4.5 的 `image` 块结构；两次实测读数（201 与 485）已逐条记进 `Docs/DeepSeekAPIDoc.md` §6.2 的「实测校准」表，可复核。

每张图前面那句文字抄 DSH 的做法（`dsh-llm` 包的 `lib/types/content.js` 里的 `requestImageHandleText`，由同包的 `lib/index.js` 再导出）：图片块自己不带路径，模型事后想再引用这个文件就得靠文字里的路径。

**同时要改**：`_buildApiMessages` 现在给每条消息无条件发一个 `text` 块（内容可能是空串，实测 DeepSeek 接受）。本次改成**空文本不发**——省一个块、也让"只有图片的 user 消息"就是纯粹的图片消息。

### D7 工具结果的结构化字段走 `image`，不走 `content`

`_executeTool` 返回的 Map 里，`read_image` 成功时同时给：

- `content`：文字信封（上面那段 `<path>…`），既给模型也给卡片显示；
- `image`：`{"path": "…", "media_type": "image/png", "width": 800, "height": 600, "bytes": 12345}`。

`toolResults` 拼装时看到 `image` 就产出两块，否则维持今天的字符串 `content`。

**理由**：`content` 保持字符串，所有既有工具、既有测试、`_elideOversizedToolResult` 的字符串语义都不动；只有带图的那一种结果变成数组。

### D8 图片在预算里的口径

- 每张图按 **1024 token** 计入（官方原文的每张上限，只会高估不会低估）；出处见 `Docs/DeepSeekAPIDoc.md` §6.2 末尾那段（含推导与实测校准）与 §6.4。
- `ContextEstimator` 与 `ContextBreakdown` 在算一条消息时：`文本估算 + 1024 × 该消息的图片张数`。
- 图片张数从 `attachments` 列（用户消息）与 `tool_calls` JSON 里的 `image` 字段（工具消息）数出来。

**理由**：估算必须"只高不低"，否则压缩阈值会在真的超限之后才触发。

### D9 压缩摘要里的图片省略说明

摘要 provider 今天只发纯文本（`model_summary_provider.dart` 的 `_messageText`）。被折进摘要的那些消息里若带图，摘要正文末尾追加一句：
`（本段另有 N 张图片，已随原文压缩省略；原始记录仍在本地数据库，可用「真实上下文」查看）`

**理由**：规则要求"砍内容必须可见，可见之后必须可恢复"。恢复路径就是 `messages.attachments` 与本地的图片文件。

### D10 数据库 v6 → v7

```sql
ALTER TABLE messages ADD COLUMN attachments TEXT;
```

- 新建库的 `CREATE TABLE messages` 里也带上这一列；
- 旧行保持 `NULL`（等价于"没有附件"）；
- 反序列化：`Message.attachments` 是 `List<String>`（路径列表），`fromRow` 解析失败按空列表处理并打一行日志（不抛）。

**理由**：与既有 v2→v3、v3→v4、v4→v5、v5→v6 的迁移写法一致，只加列、不重建表。

## Risks / Trade-offs

- **[只存路径 ⇒ 历史会变]** → 文档写明；文件缺失时换成可见的 `[图片已丢失：<path>]`，不会静默少发。用户要的是"先这样"，改法（内容哈希仓库）已在 D1 记下。
- **[默认 `input_modalities=["text"]` ⇒ 升级后贴图不生效]** → 界面提示 + 文档配置键表 + 收尾任务里改好用户自己的配置并实测。
- **[`Ctrl+V` 被输入行接管可能破坏普通文本粘贴]** → 规则钉死：剪贴板有图才贴图，否则按文本插入到光标处（替换选区）；两条分支各有一条 widget 用例。
- **[粘一张大截图会让请求体变大，且每轮重发]** → 前置检查 32 MiB/张、64 MiB/次；PNG 编码后通常远小于原始位图。**不做**编码缓存，作为已知限制记录（同一张图每轮都会重新 base64 一次）。
- **[vendor 两个 stb 单头文件增加仓库体积]** → 与既有 `third_party/json` 同一模式；只编 `stb_image_write` 与 `stb_image` 的尺寸读取部分，不用它们的解码/缩放。
- **[`deepseek-v4-pro` 这类"收图不看图"的模型]** → 靠 `input_modalities` 挡住；不尝试探测（探测要花一次请求且无法可靠判定）。

## Migration Plan

1. 数据库：v6 → v7 自动迁移，`ALTER TABLE ADD COLUMN`，不动既有行。
2. 配置：老配置缺 `input_modalities` ⇒ 按 `["text"]` 解析，行为安全（贴图会被拦下并提示），不会崩。
3. 回滚：删掉 `attachments` 列会让旧代码读不出（SQLite 不能删列，实际做法是用 v6 的 schema 打开——旧代码不认识这一列但 `SELECT *` 会带出来，`Message.fromRow` 不读它就无害）。图片文件留在 `~/.aliasagent/attachments/`，不自动清理。
4. DLL：新导出函数需要重新构建并同步到仓库根（`scripts\sync_sidecar_dll.ps1`），否则 `flutter test` 会报 `Failed to lookup symbol 'read_clipboard_image'`。

## Open Questions

无。四个待定项已由用户当场定下（模型换 `deepseek-flash`、上限照官方文档、历史只存路径、token 照官方口径估算），路线选 B（`read_image` 工具 + 用户贴图）。
