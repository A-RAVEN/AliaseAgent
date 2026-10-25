## Purpose

规定用户怎么把图片贴进对话、图片怎么落盘、怎么进入请求、以及模型不收图时怎么让用户看见结果。贴图有两个入口（按钮与 Ctrl+V），且没有图片时 Ctrl+V 必须退回普通文本粘贴；图片只存路径不存字节；请求里按 Anthropic 兼容的 image 块发出，并在前面附一段说明文本；任何"发不出去"的情况都要在界面上留一句看得见的话。

## Requirements

### Requirement: 粘贴剪贴板图片

输入行 SHALL 支持把剪贴板里的图片贴进对话，入口有两个：

1. 输入行上一个可点的「粘贴图片」按钮：点了就尝试读剪贴板里的图片；
2. 输入行接管 `Ctrl+V`：剪贴板里有图片时贴图并吞掉这次按键；没有图片时 MUST 退回普通文本粘贴（把剪贴板文本插入到当前光标处、替换当前选区），不得让 `Ctrl+V` 失效。

贴图成功后，输入区 SHALL 显示这张图的缩略图；发送前可以移除。剪贴板里没有图片时，按钮 SHALL 给出可见提示（不是静默无反应）。

#### Scenario: 剪贴板里有图片时按 Ctrl+V 贴图
- **WHEN** 剪贴板里是一张图片，焦点在输入框，用户按 `Ctrl+V`
- **THEN** 输入区出现一个缩略图待发项，且输入框里的文字内容不发生变化

#### Scenario: 剪贴板里只有文本时 Ctrl+V 仍是普通粘贴
- **WHEN** 剪贴板里只有文本 "hello"，焦点在输入框，用户按 `Ctrl+V`
- **THEN** 输入框内容变为 "hello"（若原本有选中文本则被替换），且不出现任何缩略图待发项

#### Scenario: 按钮读到空剪贴板时给出可见提示
- **WHEN** 剪贴板里没有图片，用户点「粘贴图片」按钮
- **THEN** 界面显示一句说明剪贴板里没有图片的提示；该提示 MUST 能被 `find.text` 找到

### Requirement: 粘贴的图片落盘成 PNG 文件

贴图时系统 SHALL 把剪贴板位图写成 `~/.aliasagent/attachments/` 下的一个 PNG 文件，文件名形如 `paste-<yyyyMMdd-HHmmss-SSS>-<序号>.png`。该目录不存在时 SHALL 递归创建。

写入成功后，系统 SHALL 把握手得到的绝对路径作为这条消息的唯一图片凭据；MUST NOT 把图片字节或 base64 存进数据库。

#### Scenario: 贴图后磁盘上出现 PNG
- **WHEN** 用户贴了一张图并发送
- **THEN** `~/.aliasagent/attachments/` 下存在一个新 PNG 文件，且该消息在数据库 `messages.attachments` 列里只有这个文件的路径

#### Scenario: 目录不存在时自动创建
- **WHEN** `~/.aliasagent/attachments/` 不存在时用户贴图
- **THEN** 目录被创建，PNG 写入成功，接口返回 `ok:true`

### Requirement: 图片随用户消息进入请求

发送消息时，若该条用户消息带图片，请求里对应的 user 消息 `content` SHALL 是一个内容块数组：先是文本块（消息正文非空时），然后每张图依次给一个说明文本块与一个 `image` 块。

`image` 块 SHALL 使用 Anthropic 兼容格式 `{"type":"image","source":{"type":"base64","media_type":"<类型>","data":"<base64>"}}`，`media_type` 取值只能是 `image/png` / `image/jpeg` / `image/gif` / `image/webp`。

图片前面的说明文本块 SHALL 含该图片的路径、类型、像素宽高与字节数，使模型事后能用路径再次引用这个文件。

消息正文为空（只有图片）时 MUST NOT 发空的文本块。

#### Scenario: 一条带图的用户消息
- **WHEN** 用户发了一条只有图片、没有文字的消息
- **THEN** 请求里该 user 消息的 `content` 只含「说明文本块 + image 块」，不含任何 `text` 为空的块

#### Scenario: 带文字又带图
- **WHEN** 用户发了文字 "看看这个" 并贴了一张 PNG
- **THEN** 该 user 消息的 `content` 顺序为：`text`（"看看这个"）、说明文本块、`image` 块，且 `image.source.media_type` 为 `image/png`

#### Scenario: 只有图片、没有文字也能发出
- **WHEN** 用户贴了一张图、输入框里一个字都没写，点发送按钮
- **THEN** 这条消息被发出（MUST NOT 被"空内容不提交"的守卫拦下），请求里出现该图的 `image` 块，界面出现这条带图的用户消息；输入框清空后待发缩略图也清空

### Requirement: 源文件缺失时可见

回放历史时若某条附件路径对应的文件不存在或不可读，系统 SHALL 在该位置放一个可见文本块 `[图片已丢失：<path>]` 并继续发送其余内容；MUST NOT 静默跳过该图。界面 SHALL 在该消息上显示同样的缺失提示。

#### Scenario: 文件被删掉后回放
- **WHEN** 一条历史消息带图，而该路径的文件已被删除，用户再次发消息触发回放
- **THEN** 请求里该位置是文本块 `[图片已丢失：<path>]`，同一条消息的其余文本与其余图片照常发送

### Requirement: 模型未声明图片输入时不发送并提示

当当前 Agent Type 的 `input_modalities` 不含 `image` 时，系统 SHALL NOT 把任何 `image` 块放进请求；每个本该是图片的位置 SHALL 被替换成文本块 `[图片未发送：当前模型 <model> 未声明图片输入（input_modalities 不含 image）；图片路径：<path>]`。界面 SHALL 在带图消息下方显示一行可见提示。

#### Scenario: 纯文本模型下贴图
- **WHEN** Agent Type 没有配置 `input_modalities`（缺省按 `["text"]`），用户贴了一张图并发送
- **THEN** 请求里没有任何 `image` 块，该位置是上面那句文本；界面该消息下方出现「模型未声明图片输入，本次没有发送图片」的提示

#### Scenario: 声明了 image 后正常发送
- **WHEN** Agent Type 配了 `input_modalities: ["text","image"]`，用户贴了一张图并发送
- **THEN** 请求里出现 `image` 块，界面不出现上面那条提示
