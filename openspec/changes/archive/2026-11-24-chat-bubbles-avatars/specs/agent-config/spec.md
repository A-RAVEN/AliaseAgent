## ADDED Requirements

### Requirement: Agent Type 头像字段（`avatar_path`）

Agent Type 条目 MAY 带一个可选的 `avatar_path` 字段（字符串，指向附件目录内一张图片的绝对路径），作为该模板的**头像上传覆盖**。字段缺席时 SHALL 静默读作"没有覆盖"（不打印日志——没有头像的模板是正常状态，不是配置错误）；字段存在但不是字符串、或去掉空白后为空串时 SHALL 读作"没有覆盖"并打印一行日志点名原始值（与 `input_modalities` 的回落风格一致，手误不被静默吞掉）。`toJson` SHALL 只在该字段有值时写回（缺席的模板 MUST NOT 被补上一个空键）。

**这是"读取侧"口径**：配置里的空串一律读作"没有覆盖"，MUST NOT 被当成"清除指令"或写回值。写入侧（`template.save` 的 `avatarPath` 参数）的三态语义见 `agent-template-management` 的「模板菜单支持列表、添加与修改」，两侧终态一致但入口规则不同。

该字段 SHALL NOT 影响模型的请求装配：它只决定界面画哪个头像，MUST NOT 进入系统提示词、工具定义或消息内容。

#### Scenario: 读取带头像的模板

- **WHEN** `agent_types.甲.avatar_path` 是附件目录内一个存在的图片路径
- **THEN** 运行时配置报告该模板有头像覆盖，界面的模板头像、该模板成员与会话头像都用这张图

#### Scenario: 模板没有头像字段

- **WHEN** `agent_types.甲` 没有 `avatar_path` 键
- **THEN** 运行时配置报告该模板没有头像覆盖，界面按实体 id 画身份图案，日志里没有因此产生的告警

#### Scenario: 非法头像值回落并留痕

- **WHEN** `agent_types.甲.avatar_path` 是数字、对象、或空串
- **THEN** 运行时配置报告该模板没有头像覆盖，并有一行日志点名 `avatar_path` 与原始值

#### Scenario: 写回只在有值时

- **WHEN** 分别保存一个有头像与一个没有头像的模板
- **THEN** 有头像的写回带 `avatar_path`，没有头像的写回不带该键（不写空值、不写 `null`）

### Requirement: 用户资料与头像（`profile` 块）

配置文件的顶层 MAY 有一个可选的 `profile` 对象，装**本机用户的资料**：`avatar_path`（用户头像的上传覆盖路径）与 `user_id`（用户标识，用作身份图案的哈希种子）。两者 SHALL 都是字符串；**字段缺席时 SHALL 静默读作"没有该值"（不打印日志——没有资料是正常状态）**；字段存在但不是字符串、或去掉空白后为空串时 SHALL 读作"没有该值"并打印一行日志点名该字段与原始值。与 `avatar_path` 一样，这里的空串是"读取侧"的回落值，不是清除指令；写入侧见 `web-management-ui` 的「用户头像（侧栏入口与 `profile.save`）」。

`profile` 块本身缺席、或不是对象时 SHALL 读作"没有用户资料"（缺席静默、类型不对打一行日志），界面按缺省的常量种子画身份图案。`user_id` 缺席时身份图案的种子 SHALL 取产品的具名常量缺省值——常量 `kDefaultUserSeed = 'local-user'` 定义在 `lib/models/user_profile.dart`；系统 MUST NOT 自动生成、MUST NOT 在保存时凭空写回一个 `user_id`（只有用户显式在配置里写了才有）。

`config.get` 返回的 `profile` SHALL 同时给出**实际生效**的身份图案种子 `identitySeed`（= `user_id` 若存在，否则等于常量缺省值），使客户端不必各自复制这个常量；`identitySeed` 是读取期派生值，MUST NOT 被写进配置文件。

`toJson` SHALL 只在 `avatar_path` 与 `user_id` 至少一项有值时写回 `profile` 块；两者都没有时 MUST NOT 写出该块（旧配置不因升级产生无意义差异）。

保存路径 SHALL 保护该块：只提交 provider 表的 `config.save` MUST NOT 抹掉已存在的 `profile`；写用户头像的 `profile.save` SHALL 整份写回配置，providers / agent_types / search / spill / tool 一律原样保留。

#### Scenario: 读取用户资料

- **WHEN** 配置里 `profile` 为 `{"avatar_path": "<附件目录内一张图>", "user_id": "alice"}`
- **THEN** `config.get` 返回该头像路径、该用户标识与实际生效种子 `alice`，界面上用户消息旁显示这张图

#### Scenario: 没有 profile 块

- **WHEN** 配置里没有 `profile` 键
- **THEN** 用户头像按常量种子画身份图案，`config.get` 返回空的头像路径、空的用户标识与 `identitySeed = "local-user"`，日志没有因此产生的告警

#### Scenario: 非法 profile 或字段回落并留痕

- **WHEN** `profile` 是字符串/数组，或 `profile.avatar_path` 是数字、`profile.user_id` 是空串
- **THEN** 相应值读作"没有该值"，有一行日志点名字段与原始值，其余字段照常解析；`identitySeed` 回落到常量缺省值

#### Scenario: 保存时只写有值的块

- **WHEN** 用户从未设置头像与标识，或清除了头像且没有手写 `user_id`
- **THEN** 写回的配置里没有 `profile` 块（不写空对象、不写空字符串键），也没有凭空写出的 `identitySeed` 键

#### Scenario: 只提交 provider 的保存不抹掉用户资料

- **WHEN** 配置里已有 `profile`，用户在 Provider 页保存一次（该保存只提交 provider 表）
- **THEN** 写回后 `profile` 仍在，头像路径与用户标识逐字不变

#### Scenario: 恢复默认头像清掉键

- **WHEN** 用户对已有头像点「恢复默认」
- **THEN** 写回的配置里 `profile.avatar_path` 不存在，界面回到身份图案；若 `profile` 已无其它值，整个块也不写出
