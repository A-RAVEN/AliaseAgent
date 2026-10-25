## Purpose

给模型一个"看图"的工具：read_image 读工作区里的位图，返回给模型一段文字信封（路径、类型、宽高、字节数）与给 Dart 拼图片块用的结构化元数据。格式按文件头魔数判定，路径限制与 read_file 一致，超过官方尺寸/字节上限前置报错，模型没声明图片输入能力时直接失败而不是白烧一轮。

## Requirements

### Requirement: read_image 工具

C++ Sidecar SHALL 实现 `read_image` 工具，入参 `{"path": "<工作区内路径>"}`，成功时返回 JSON：

```json
{"ok":true,"content":"<path>…</path>\n<type>image</type>\n<content>\nimage/png image, 800x600 px, 12345 bytes\n</content>",
 "image":{"path":"…","media_type":"image/png","width":800,"height":600,"bytes":12345}}
```

`content` 是给模型的文字信封（含路径、类型、宽高、字节数四样），`image` 是给 Dart 拼 `image` 内容块用的结构化元数据。工具定义 SHALL 出现在 Dart 的工具清单里，名字为 `read_image`。

`content` 信封里的 `<path>` 与 `image.path` 两处 MUST 都是**工作区解析后的绝对路径**，不是模型传进来的那串（模型常传工作区相对路径，例如 `blue64.png`）。理由：Dart 侧要拿这个路径去读文件 —— 工具卡片画缩略图、下一轮请求拼 `image` 块都从它来，而界面进程的工作目录不是工作区，相对路径在那儿打不开（13.2 实测踩到：卡片显示 `[图片已丢失：blue64.png]`）。错误文案里的路径仍用模型传的那串（错误说的是"你给的哪个路径有问题"）。

#### Scenario: 读一张 PNG
- **WHEN** 模型调用 `read_image`，路径指向工作区里一张 800×600 的 PNG
- **THEN** 返回 `ok:true`，`image.media_type` 为 `image/png`、`width` 为 800、`height` 为 600，`content` 里同时含该路径与 `800x600`

#### Scenario: 工具结果同时带图片块
- **WHEN** `read_image` 成功，Dart 拼下一轮请求
- **THEN** 对应 `tool_result` 的 `content` 是一个数组，第一块是上面的文字信封，第二块是 `{"type":"image","source":{"type":"base64",…}}`

### Requirement: 格式按文件内容判定

`read_image` SHALL 先用扩展名筛（只接受 `.png` / `.jpg` / `.jpeg` / `.webp` / `.gif`），再用文件头魔数确认实际格式。扩展名声明的格式与字节实际格式不一致时 SHALL 报错 `Image type mismatch: <path>`；扩展名不在表里时 SHALL 报错 `Not an image: <path>（扩展名 .xxx 不声明受支持的图片格式；只接受 .png/.jpg/.jpeg/.webp/.gif）`。

#### Scenario: 扩展名撒谎
- **WHEN** 一个实际是 JPEG 的文件被命名成 `a.png`，调用 `read_image`
- **THEN** 返回 `ok:false`，错误文本为 `Image type mismatch: a.png`

#### Scenario: 不是图片的扩展名
- **WHEN** 调用 `read_image` 读 `notes.txt`
- **THEN** 返回 `ok:false`，错误文本以 `Not an image: notes.txt` 开头

### Requirement: 路径限制与既有文件工具一致

`read_image` SHALL 使用与 `read_file` 相同的路径解析与工作区限制：解析到工作区之外的路径 SHALL 报错 `Access denied: path outside workspace`；路径不存在 SHALL 报错 `File not found: <path>`；路径是目录 SHALL 报错 `Path is a directory, not a file: <path>`（与 `sidecar/src/tools.cpp` 里既有的三处同文案保持一致，不另造一句）。

#### Scenario: 工作区外
- **WHEN** 调用 `read_image` 传 `..\..\secret.png`
- **THEN** 返回 `ok:false`，错误文本为 `Access denied: path outside workspace`

### Requirement: 图片上限前置检查

`read_image` SHALL 在返回图片前检查官方限制（数值出处：`Docs/DeepSeekAPIDoc.md` §6.4.3）：

- 单张字节数 ≤ 33554432（32 MiB），超出报错 `Image too large: <path>（<N> 字节，单张上限 33554432 字节）`；
- 单边像素 ≤ 8192，超出报错 `Image dimension too large: <path>（<W>x<H>，单边上限 8192 像素）`。

#### Scenario: 超过 32 MiB
- **WHEN** 读一张 40 MiB 的 PNG
- **THEN** 返回 `ok:false`，错误文本含 `Image too large:` 与 `33554432`

#### Scenario: 单边超过 8192
- **WHEN** 读一张 9000×100 的 PNG
- **THEN** 返回 `ok:false`，错误文本含 `Image dimension too large:` 与 `8192`

### Requirement: 模型未声明图片输入时 read_image 直接失败

Dart 在分发 `read_image` 之前 SHALL 检查当前 Agent Type 的 `input_modalities` 是否含 `image`；不含时 MUST NOT 调用 sidecar，直接返回错误 `cannot read "<path>" as an image: model "<model>" does not declare image input (input_modalities)`。错误 SHALL 出现在工具卡片上。

**理由**：模型看不到图的模型调用这个工具只会白烧一轮请求；直接说清原因比塞一段"图片未发送"的占位文字更有用。

#### Scenario: 纯文本模型调用 read_image
- **WHEN** `input_modalities` 缺省（只有 `text`）时模型调用 `read_image`
- **THEN** 工具卡片状态为 Error，错误文本含 `does not declare image input`，且 sidecar 的 `read_image` 未被调用
