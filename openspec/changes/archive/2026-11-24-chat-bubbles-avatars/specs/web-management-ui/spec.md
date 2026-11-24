## MODIFIED Requirements

### Requirement: agent 模板编辑

核心 SHALL 提供 `template.list/save/delete`。template.save SHALL 走 AgentTemplateController.validate/save（保持配置完整，未开放字段原样保留）；字段含 provider/model/tools/systemPrompt/thinkingEffort（五档）/maxContextTokens/**input_modalities（模态勾选，选目录模型时回填）**/压缩阈值（kDefault*）/**头像（`avatarPath`：上传、预览、清除）**。**生效时机分两类**：thinking_effort 对运行中 Agent 下一消息生效；model/tools/window/systemPrompt 只作用于之后创建或恢复的 Agent。**头像不属于这两类**：它不进模型请求，保存后界面重拉即可让该模板的头像在成员卡片、气泡与模板页上更新，SHALL NOT 要求重建 Agent 实例。web 模板页 SHALL 显式提示这一生效时机（复刻 kAgentTemplateEffectiveNote）。模板名创建后 MUST NOT 可改。

模板页的头像控件 SHALL：显示当前头像（上传图或身份图案）、提供选择图片的入口、提供清除入口。头像预览 SHALL 经 `attachment.read` 换成 data URL 后渲染，MUST NOT 把附件目录的绝对路径直接塞进 `<img src>`。上传 SHALL 复用 `attachment.upload`（同一套大小上限与文件头魔数判定），保存 SHALL 把得到的路径作为 `avatarPath` 交给 `template.save`；清除 SHALL 提交**空串**（`avatarPath: ''`）使配置里不再有该键。用户没有碰过头像时，保存 SHALL **省略** `avatarPath`（= 不改），MUST NOT 因为页面没带上这个字段而清空既有头像。模板页 MUST NOT 另建上传接口、MUST NOT 在浏览器里做第二套图片校验去替代核心的校验；上传或保存失败时 SHALL 显示可归因错误（点名原因），MUST NOT 静默丢弃用户的选择。

#### Scenario: 编辑模板生效时机分两类

- **WHEN** 用户修改模板的 thinkingEffort 与 model 并保存
- **THEN** thinkingEffort 对运行中对话下一消息生效；model 只对之后创建/恢复的会话生效，运行中实例 model 不变；界面显示生效时机提示

#### Scenario: 编辑 input_modalities 解锁图片

- **WHEN** 用户在模板编辑勾选 image 模态并保存
- **THEN** 该模板新会话接受图片输入（acceptsImages 为真）

#### Scenario: 保存保持配置完整

- **WHEN** 保存模板
- **THEN** 未开放编辑的受支持字段（命令超时/不可压缩要求/压缩参数等）原样保留，不静默丢失

#### Scenario: 模板页上传头像

- **WHEN** 用户在模板页为模板「甲」选择一张图片并保存
- **THEN** 先发 `attachment.upload` 拿到路径，再发 `template.save` 且 payload 的 `avatarPath` 是同一个路径；模板页预览更新为该图，重拉 `template.list` 后该模板仍带头像

#### Scenario: 清除模板头像

- **WHEN** 用户点清除某个模板的头像并保存
- **THEN** `template.save` 的 payload 里头像为空串（`avatarPath: ''`，清除语义），写回后该模板的 `avatar_path` 键消失，模板页预览回到身份图案

#### Scenario: 没碰头像的保存不清空既有头像

- **WHEN** 用户只改一个有头像模板的模型并保存，编辑过程中没碰头像控件
- **THEN** `template.save` 的 payload 省略 `avatarPath`，写回后该模板的 `avatar_path` 与原来逐字一致

#### Scenario: 新增模板不继承头像

- **WHEN** 用户在模板页新增一个模板并保存，没选头像
- **THEN** `template.save` 的 payload 省略 `avatarPath`，新模板没有 `avatar_path`，预览是身份图案（MUST NOT 沿用 general 的头像）

#### Scenario: 上传失败可归因且不丢选择

- **WHEN** 用户选择的文件超过单张上限、或文件头魔数不是支持的图片格式
- **THEN** 模板页显示可归因错误（点名上限或格式判定依据），既有头像不变，用户可重新选择

## ADDED Requirements

### Requirement: 用户头像（侧栏入口与 `profile.save`）

web 客户端 SHALL 在**会话侧栏底部**提供用户头像块：显示头像是用户头像（上传图，没有则是身份图案）、一个「换头像」入口与一个「恢复默认」入口。用户头像的图片 SHALL 经 `attachment.read` 换成 data URL 后渲染（MUST NOT 把绝对路径塞进 `<img src>`）。换头像 SHALL 复用 `attachment.upload` 上传，再把路径交给核心的 `profile.save`；恢复默认 SHALL 调 `profile.save` 并传**空串**。成功后 SHALL 立即更新界面上的用户头像（用户消息气泡、群聊用户消息），MUST NOT 要求用户刷新整页才生效。

`config.get` SHALL 返回 `profile`（用户头像路径、用户标识与实际生效种子 `identitySeed`），使页面刷新后仍能画出同一个头像；`profile` 缺失时按身份图案渲染。**读取失败**（`config.get` 抛错）时头像块 SHALL 显示可归因的可见提示（含「重试」），MUST NOT 静默把失败当成"没有头像"。

核心 SHALL 提供 `profile.save{avatarPath}`：`avatarPath` SHALL **必填字符串**——`''` 表示清除该键、非空表示设为该路径、省略 / `null` / 其它类型 SHALL 返回 `-32602`（它是一次写操作，不允许"什么都没写"却返回成功）。非空路径必须是注入附件目录内**确实存在的文件**（目录边界与"是文件"的判定复用 `attachment.read` 的同一写法），否则返回可归因的 `-32602` 错误（点名路径与目录）；成功 SHALL 把整份配置写回磁盘（providers / agent_types / search / spill / tool 原样保留）并返回更新后的 `profile`。`profile.save` SHALL 同步进 `kCoreRpcMethodNames` 与用户文档的 RPC 表（沿用「管理 RPC 面同步与可归因」的条款），MUST NOT 只实现不登记。

#### Scenario: 换头像后整页用户头像同步

- **WHEN** 用户从侧栏用户头像块选择一张图片
- **THEN** 客户端发出 `attachment.upload` 与 `profile.save`（payload 带刚拿到的路径），成功后所有用户消息气泡与侧栏头像都换成本地图片，不需要刷新页面

#### Scenario: 恢复默认头像

- **WHEN** 用户点「恢复默认」
- **THEN** `profile.save` 的 payload 头像为空串，写回的配置里不再有 `profile.avatar_path`，界面上用户头像回到身份图案

#### Scenario: 刷新后头像仍在

- **WHEN** 用户设置头像后刷新浏览器
- **THEN** `config.get` 返回同一个 `profile.avatarPath`，侧栏与气泡显示同一张图，不出现「刷新后变回默认图案」

#### Scenario: 头像资料读取失败可见

- **WHEN** 页面打开时 `config.get` 失败
- **THEN** 侧栏用户头像块显示「头像资料读取失败：…」与重试入口，头像按身份图案渲染，聊天屏与群视图照常加载（MUST NOT 因为这次失败挡住消息）

#### Scenario: 头像保存缺字段或类型错被拒

- **WHEN** `profile.save` 的 `avatarPath` 被省略、传 `null`、或传数字
- **THEN** 返回 `-32602` 并点名 `avatarPath`，配置与界面头像都不变（不允许"静默当成功"）

#### Scenario: 头像保存失败可归因

- **WHEN** `profile.save` 收到附件目录之外或已不存在的路径
- **THEN** 返回可归因错误（点名路径与附件目录），配置不变，界面显示该错误而不是静默失败

#### Scenario: 只提交 provider 的保存不抹用户头像

- **WHEN** 用户已有头像，随后在 Provider 页保存一次
- **THEN** 写回后 `profile.avatar_path` 逐字不变，刷新后头像仍是那张图

#### Scenario: 方法清单与文档同步

- **WHEN** 核心启动注册管理方法
- **THEN** `kCoreRpcMethodNames` 含 `profile.save` 且 `_registerMethods` 有实现（漏实现抛错），用户文档的 RPC 表里也有这一行

#### Scenario: 没有 profile 时用身份图案

- **WHEN** 配置文件里没有 `profile` 键
- **THEN** 侧栏用户头像块与用户气泡都显示由常量用户标识生成的身份图案，界面不报错、不显示空图片框
