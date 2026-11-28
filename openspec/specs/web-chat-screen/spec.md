# web-chat-screen Specification

## Purpose

规定 AliasAgent web 聊天屏的完整 UI 行为契约：live 与 history 共用统一渲染路径下的消息/工具轮/思考渲染与默认单行折叠、贴底自动跟随与悬浮跳底、会话列表虚拟滚动、消息分页加载（首屏尾锚 + 上翻更早）、WebSocket 自动重连与心跳、应用壳层常驻左侧会话列表与主区按 kind 切换、单聊消息的左右气泡与头像（用户右 / agent 左，与群聊同一套组件；头像按模板上传覆盖或身份图案渲染，字节经附件接口取回），以及设计系统约束与渲染审计。

## Requirements

### Requirement: 消息与工具轮渲染一致且不产生空气泡
web 聊天屏 SHALL 用统一渲染路径处理 live 事件与 history 加载，二者对同一消息形状 MUST 产生一致渲染。一致 SHALL 经归一/合并/去重达成：live 的 tool.call/tool.result 事件按 activity.id 合并进对应消息 toolCalls（name→toolName 归一、补 status/result），thinking 按 index 归一；最终消息聚合的整轮 toolCalls 与中间消息重叠 SHALL 去重（最终消息只渲染正文、不重复渲染聚合工具卡）。助手消息正文非空 SHALL 渲染 Markdown 气泡；其 toolCalls/thinking SHALL 内联渲染成卡片。**空正文工具轮消息（content 空、toolCalls 非空）MUST NOT 渲染成独立空气泡**，SHALL 按**每个 toolCall 一张单行折叠卡**渲染（多工具消息=多张卡，折叠态须能辨每个工具的存在，MUST NOT 一卡只露一个工具而略去其余无标记）。真回复 MUST 可见，不被工具轮空壳或重复卡淹没。

#### Scenario: 工具轮不产生空气泡
- **WHEN** 加载或收到一条 content 为空、toolCalls 非空的助手消息
- **THEN** 每个 toolCall 渲染成一张单行折叠卡（工具名+状态+输入摘要），不出现写着 ASSISTANT 却无内容的空气泡

#### Scenario: 多工具消息每工具可见
- **WHEN** 一条助手消息含多个 toolCalls
- **THEN** 折叠态每个工具各有一张单行卡（或带计数标记聚合卡），不略去其余工具而无标记

#### Scenario: 真回复可见且不重复
- **WHEN** 一轮含多次工具调用后产生最终文字回复
- **THEN** 最终回复渲染成 Markdown 气泡且可见，工具卡按 id 去重不渲染两遍

#### Scenario: live 与 history 一致
- **WHEN** 同一条助手消息分别经 live 事件（工具执行前原始形状+后续 tool.result）与 history 加载（富化形状）渲染
- **THEN** 经按 id 合并/归一后两者渲染形状一致，不出现 live 工具卡永停 executing 而 history 是 done 的分叉

### Requirement: 工具与思考卡片默认折叠且折叠态单行
工具调用卡与思考卡 SHALL 默认折叠；折叠态 SHALL 严格只占一行高度（单行截断），MUST NOT 折叠后仍占多行。展开 SHALL 能看全文（折叠不等于丢弃内容）。

#### Scenario: 默认折叠单行
- **WHEN** 工具卡或思考卡首次渲染
- **THEN** 处于折叠态且高度为单行（工具名/状态/摘要单行截断）

#### Scenario: 展开看全文
- **WHEN** 用户点击折叠卡
- **THEN** 展开显示完整输入/结果/思考内容，内容可滚，无丢失

### Requirement: 流式语义正确
聊天屏 SHALL 在每条 assistant.message（含中间工具轮 isFinal=false）落定当轮流式文本（清流式缓冲、追加该轮气泡）；assistant.chunk 累积进流式缓冲。**整轮流式态 SHALL 以 agent.streaming 事件为准**，MUST NOT 用 turn.completed（每次 API 请求结束即发）判整轮"正在生成"——工具执行期间整轮仍 streaming=true。

#### Scenario: 中间轮落定不串轮
- **WHEN** 工具轮产生 assistant.message(isFinal=false) 带该轮文本，随后下一轮 chunk 到达
- **THEN** 该轮文本落定成气泡、流式缓冲清空，下一轮 chunk 不累积进上一轮残留文本

#### Scenario: 工具执行期间仍在生成
- **WHEN** 一轮工具调用执行中（turn.completed 已发但整轮未结束）
- **THEN** 整轮流式态仍为 true（以 agent.streaming 为准），"正在生成"指示不闪断

### Requirement: 贴底自动跟随
消息列表处于底部时，新内容（消息/工具卡/流式增量）到达 SHALL 自动滚到底；用户上翻阅读历史（非贴底）时 SHALL NOT 自动滚动打扰。贴底判定 SHALL 用滚动位置阈值（bottomThreshold 为设计 token，取自间距 scale，不发明魔数）。

#### Scenario: 贴底时跟随
- **WHEN** 列表已在底部且新消息到达
- **THEN** 自动滚到底，用户无需手动拖

#### Scenario: 上翻时不打扰
- **WHEN** 用户上翻离开底部后有新消息到达
- **THEN** 不自动滚动，保持用户阅读位置

### Requirement: 悬浮跳底按钮
非贴底时 SHALL 显示悬浮"回到底部"按钮（圆形 chevron-down，参照 DSH，位于输入框上方）；点击 SHALL 滚到底并恢复贴底跟随；贴底时 SHALL 隐藏该按钮。

#### Scenario: 非贴底显示并可跳底
- **WHEN** 用户上翻离开底部
- **THEN** 显示跳底按钮，点击后滚到底并恢复贴底跟随

#### Scenario: 贴底隐藏
- **WHEN** 列表处于底部
- **THEN** 跳底按钮隐藏

### Requirement: 会话列表虚拟滚动
会话列表 SHALL 虚拟化渲染，数百~数千会话时只渲染可视区，MUST NOT 因全量渲染 DOM 卡顿。

#### Scenario: 大量会话不卡
- **WHEN** 会话列表含数百条以上会话
- **THEN** 只渲染可视区项，滚动流畅，DOM 节点数受控

### Requirement: 消息分页加载（首屏尾锚 + 上翻更早）
聊天屏 SHALL 用 message.query 游标分页加载历史：**首屏锚定最新一页**（anchor=tail），上翻到顶用反向游标（prevCursor/beforeSeq）加载更早一页，加载更早页 SHALL 保持滚动位置不跳。MUST NOT 一次性把整条历史载入渲染。message.query 的尾锚与反向游标能力由 web-core-shim 分页能力的 additive 扩展提供（见该能力 MODIFIED delta）。

#### Scenario: 首屏最新一页
- **WHEN** 打开一个会话
- **THEN** 首屏加载最新一页消息（anchor=tail，pageSize 由 UI 给定），用户直接看到最新回复，不全量载入、不从最旧页开场

#### Scenario: 上翻加载更早
- **WHEN** 用户上翻到顶且仍有更早消息
- **THEN** 用 prevCursor 加载更早一页并保持滚动位置不跳

### Requirement: WebSocket 自动重连与心跳
RpcClient SHALL 在连接断开时自动重连（指数退避），并以心跳（周期 core.ping）探测连接存活；重连参数 SHALL 可配或有出处，不裸写魔数。重连成功 SHALL 恢复当前会话订阅与状态，重连中 SHALL 显示明确态。

#### Scenario: 断开自动重连
- **WHEN** WS 连接断开
- **THEN** 客户端按退避自动重连，而非停在"已断开"需手动刷新

#### Scenario: 心跳探活
- **WHEN** 连接闲置但心跳超时未回应
- **THEN** 判定连接死亡并触发重连

#### Scenario: 重连恢复状态
- **WHEN** 重连成功
- **THEN** 重拉当前会话当前页消息恢复状态，后续事件经核心广播到达当前订阅者（核心无 ensure RPC，不依赖再发消息）；重连中显示明确态

### Requirement: 设计系统约束与渲染审计
web 聊天屏 SHALL 先定设计 tokens（方向/调色板/字阶/间距/组件约束）再写组件；组件 MUST NOT 写裸 hex 或任意间距值（取自 tokens）。渲染结果 SHALL 经 design_audit 审计，违规须修复或显式说明 deliberate 例外。

#### Scenario: tokens 集中
- **WHEN** 审查组件样式
- **THEN** 颜色/字号/间距均取自集中 tokens，无裸 hex/任意间距

#### Scenario: 渲染审计
- **WHEN** 对渲染页跑 design_audit
- **THEN** 文本尺寸/颜色数受控、对比度达 WCAG AA、间距落 grid、控件可点；违规被修复或显式说明

### Requirement: 会话列表常驻左侧与主区切换

web 客户端 SHALL 在**应用壳层**渲染常驻左侧的会话列表，主区位于其右；全页 SHALL 恰好存在一个会话列表节点（`data-testid="session-list"`），其祖先链含 `data-testid="session-sidebar"`；列表 SHALL NOT 由单聊聊天屏或群聊主区各自渲染。会话列表 SHALL 同时包含单聊与群聊，并按 `kind` 区分：群聊行 SHALL 带可见标记与 `data-kind="group"`，单聊行 `data-kind="single"`；排序 SHALL 采用 `session.list` 返回的顺序，前端 MUST NOT 重排。

主区内容 SHALL 由当前选中会话的 `kind` 决定：`group` → 群聊主区，`single` → 单聊主区，无选中 → **空聊天屏**（标题「（未选择会话）」、输入禁用、消息为空、快照/计量/提示条 MUST NOT 残留上一条会话）。打开群聊、切回单聊、打开或关闭管理面板 MUST NOT 卸载、隐藏或清空会话列表，也 MUST NOT 重置其滚动位置或选中态。管理面板（Provider / 模板）SHALL 只覆盖主区，列表保持可见可点；从列表选中、新建会话或新建群聊时管理面板 SHALL 关闭。

列表操作（选中、新建、删除）导致当前会话变化后，主区 SHALL 按**新会话**的 `kind` 激活：删除群行 SHALL 走 `group.delete`（停链、销毁成员实例、级联删数据），删除单聊行 SHALL 走 `session.delete`；删除后下一条是群聊时 MUST NOT 按单聊加载（反向也必须按 `kind`）。激活新会话 SHALL 清空上一条会话的聊天视图、快照、计量、技能失败、提示、群流式成员与群链状态，MUST NOT 把旧内容显示在新会话标题下。

群聊数据未就绪（摘要或首屏消息未齐）时主区 SHALL 显示加载占位；首屏首次 `message.query` 失败时占位 SHALL 保留并显示可归因错误，MUST NOT 用空时间线/`timeline-empty` 冒充加载完成。**重载失败**（已有首屏内容后由 7 处 `onReload` 或消息事件触发）SHALL 保留已加载的时间线/成员/游标/快照，只显示错误并清链/流式状态，MUST NOT 把整页打回 `group-loading`。快速切换群聊时，旧群的晚到响应 SHALL 被丢弃：每个群加载请求 SHALL 有代次/`sessionId` 守卫，过期响应 MUST NOT 提交到新群。群加载入口 SHALL 先核对 `currentSessionIdRef` 再自增代次，旧群 `onReload` 的续体 MUST NOT 让新群在途加载失效（否则新群永久占位）；`refreshAfterReconnect` 用旧 `sessionId` 发起的加载同样 MUST NOT 顶掉新群。

单聊加载失败 SHALL 有可归因错误出口：`message.query` 失败时显示 `error-banner` 的「加载会话失败：…」，MUST NOT 产生 unhandled rejection 或静默清空主区；失败 catch SHALL 核对 `currentSessionIdRef`，不把旧会话错误挂到新会话。`session.create` / `session.delete` / `group.delete` 成功后若后续加载失败，错误文案 MUST NOT 变成「新建/删除失败」——操作错误与加载错误 SHALL 分开；`reloadSessions` 的 `session.list` 失败 SHALL 单独显示「列表刷新失败：…」，MUST NOT 混成删除/新建失败。

主区 SHALL 是页面唯一的 `main` 地标：单聊、群聊、群加载占位、成员视图四个状态下 `document.querySelectorAll('main').length === 1` 且该 `main` 可见，MUST NOT 把唯一 `main` 藏在 `display:none` 的面板里。

群行重命名后主区标题 SHALL 同步（`session.title` 事件同样同步）；群聊打开时模板选择器 SHALL 禁用或隐藏，并说明「群聊模板由各成员决定」，MUST NOT 让用户以为可以切模板。删除当前会话时管理面板 SHALL 关闭，MUST NOT 让管理页继续盖着已删除会话的主区。

窄屏下左列 SHALL 保持可见且完整，主区 MUST NOT 与左列重叠或产生横向滚动。

#### Scenario: 打开群聊时会话列表不消失且唯一

- **WHEN** 用户在左侧列表点开一个群聊会话
- **THEN** 全页仍只有一个 `session-list` 节点（祖先为 `session-sidebar`），列表宽度不变，其它会话行仍可点击；主区显示群聊，而不是整屏被替换

#### Scenario: 群聊与单聊来回切换列表不动

- **WHEN** 用户先打开群聊、再点一个单聊、再点回群聊
- **THEN** 主区在群聊与单聊之间切换，会话列表节点始终唯一、选中态跟随当前会话、列表的滚动位置不被重置

#### Scenario: 单聊群聊混排且可区分

- **WHEN** `session.list` 同时返回单聊与群聊
- **THEN** 两类会话出现在同一张列表里（不分成两个列表），群聊行有可见的「群」标记且 `data-kind="group"`，单聊行 `data-kind="single"`

#### Scenario: 管理面板只覆盖主区

- **WHEN** 用户打开 Provider 页或模板页
- **THEN** 管理页只盖住主区，左侧会话列表仍可见、可点（`elementFromPoint` 命中列表而不是覆盖层）；点一个会话后管理页关闭，主区切到该会话

#### Scenario: 删除群行走 group.delete

- **WHEN** 用户在会话列表删除一个群聊并确认
- **THEN** 客户端发出 `group.delete`（payload 带该 `groupId`），而不是 `session.delete`；删除后列表移除该群，当前选中按新会话的 `kind` 激活

#### Scenario: 删除当前会话后按类型激活下一条

- **WHEN** 当前选中一个单聊，删除它后列表里下一条是群聊
- **THEN** 主区按群聊激活（加载该群的成员与消息），不把群聊当单聊加载，也不停留在一个永不完成的群聊占位；反向（删群后下一条是单聊）同样按单聊加载

#### Scenario: 群聊重命名后主区标题同步

- **WHEN** 用户在当前群聊的会话行里内联改名并确认
- **THEN** 列表行与群聊主区标题都显示新标题；`session.title` 事件到达时同样同步，不出现「行已改名、主区还是旧标题」

#### Scenario: 群聊打开时模板选择器禁用并说明

- **WHEN** 当前会话是群聊
- **THEN** 会话侧栏的模板选择器被禁用或隐藏，并显示「群聊模板由各成员决定」的说明；界面不会让用户对群聊发起 `session.switchTemplate`

#### Scenario: 群聊数据未就绪或失败时显示占位

- **WHEN** 用户切换到一个新群聊，`group.list` 或首屏 `message.query` 尚未返回，或 `message.query` 失败
- **THEN** 主区显示群聊加载占位，不显示上一个群聊的成员或消息；失败时占位保留并显示可归因错误，MUST NOT 显示空时间线/`timeline-empty` 冒充加载完成

#### Scenario: 快速切群时过期响应不挂到新群

- **WHEN** 用户从群 A 切到群 B，A 的 `group.list` / `message.query` / `group.view` 晚于 B 返回
- **THEN** 主区仍是 B 的标题、成员与消息，A 的摘要、消息、快照与错误都不提交到 B 的界面

#### Scenario: 旧群续体不顶掉新群加载

- **WHEN** 用户点开群 A（`group.list` 延迟），随后点开群 B，再切回群 A；期间旧群 A 的 `onReload` 续体还在执行
- **THEN** 每个目标群最终都能加载出自己的内容，不出现「新群永久停在占位、无重试」；旧群续体不得把新群的加载代次顶掉

#### Scenario: 单聊加载失败显示错误条且不误报操作失败

- **WHEN** 用户点开一个单聊，`message.query` 失败；或新建/删除会话的 RPC 成功但随后加载失败；或 `reloadSessions` 的 `session.list` 失败
- **THEN** 主区显示 `error-banner` 的「加载会话失败：…」或「列表刷新失败：…」，页面无 unhandled rejection；后两种情况 MUST NOT 显示「新建会话失败 / 删除会话失败」，且加载失败 catch 带当前会话守卫，不把旧会话错误挂到新会话

#### Scenario: 群聊重载失败保留已加载内容

- **WHEN** 群聊 A 已成功显示时间线与成员，随后一次 `onReload` 的 `group.list` 或 `message.query` 失败
- **THEN** 时间线、成员、游标与快照仍保留，页面显示错误条，MUST NOT 退回 `group-loading`；链状态与流式成员清空，取消按钮不被旧链误启用；只有首屏首次加载失败才显示占位

#### Scenario: 主区地标唯一且可见

- **WHEN** 页面分别处于单聊、群聊标签、群加载占位、成员视图四个状态
- **THEN** `document.querySelectorAll('main').length === 1`，且该 `main` 的 `offsetParent` 非空（未被 `display:none` 隐藏）

#### Scenario: 删除当前会话时管理面板关闭

- **WHEN** 用户打开 Provider 页或模板页，然后从左侧会话列表删除当前会话
- **THEN** 管理面板关闭（`panel-overlay` 消失），主区按新会话加载或显示空聊天屏，不继续盖着已删除会话的主区

#### Scenario: 空选中是空聊天屏

- **WHEN** 没有任何选中会话（例如删除了最后一条）
- **THEN** 主区显示空聊天屏：标题「（未选择会话）」、输入禁用、消息为空，快照/计量/错误条不残留上一条会话

#### Scenario: 切换会话清空旧快照与计量

- **WHEN** 用户从一个有上下文快照与 token 计量的单聊切到一个新会话
- **THEN** 新会话下不显示上一条会话的 `context-snapshot`、占用环、真实上下文或计量数字；旧数据只在重新加载新会话后由新数据替换

#### Scenario: 窄屏主区不压住列表

- **WHEN** 浏览器宽度为 720px 且用户打开一个群聊
- **THEN** 左侧会话列表仍完整可见，主区从其右侧开始、不重叠，页面没有横向滚动

### Requirement: 单聊消息气泡与头像

web 聊天屏的单聊主区 SHALL 用与群聊同一套聊天式左右气泡与头像组件渲染消息，MUST NOT 再用「全宽/靠边卡片 + You/Assistant 大写标签」的形态：

- 用户消息 SHALL 靠右、绿气泡，用户头像位于该行**最右端**；
- 助手消息（含流式消息）SHALL 靠左，agent 头像在最左、气泡在右；单聊 SHALL NOT 再画发言者名字（只有一个 agent，名字是噪音）；
- 「正在生成…」指示行 MUST NOT 配头像（它不是一条消息，而是一个状态指示）；
- 气泡 SHALL 是消息行**内部**的元素（行容器保留既有标识、整行含头像），靠哪边、多宽 SHALL 由内层气泡体现并可按内层气泡度量；
- 气泡宽度上限、圆角与内外间距 SHALL 取自既有设计令牌/既有类名，MUST NOT 新写裸色值与任意间距。

头像来源 SHALL 按此顺序：①该会话所属模板的 `avatar_path`（上传覆盖，能取到图片字节时才用）；②否则用该**会话 id** 生成的身份图案（纯前端 SVG、5×5 横向对称网格 + 一档派生色、确定性：同一会话永远同一图案，会话改名 MUST NOT 改变图案）。用户头像 SHALL 取 `profile.avatar_path`，没有则用用户标识生成的身份图案。**头像图片 SHALL 经 `attachment.read` 换成 data URL 后渲染**，MUST NOT 把附件目录的绝对路径、`file://` 地址或由路径拼出的 URL 直接塞进 `<img src>`（静态服务拒绝 web 根外文件，浏览器拿不到）。头像图片取不到字节（文件被删或移走）时 SHALL 回落身份图案并在 DOM 上标出来源（`data-avatar-source`），MUST NOT 弹错误横幅、MUST NOT 让消息渲染失败。

气泡内的既有内容 SHALL 保持：附件缩略图、以及「图片未发送」「图片已丢失」两类可见提示行 MUST NOT 因改气泡而消失或改文案；live 事件与历史加载对同一条消息 SHALL 渲染成同一种形态（气泡 + 头像 + 正文），MUST NOT 出现一边是气泡、另一边还是旧卡片的分叉。

#### Scenario: 用户消息靠右带头像

- **WHEN** 单聊里用户发一条文本消息
- **THEN** 该消息是绿气泡、整体贴在消息区右侧，用户头像在这一行的最右端；MUST NOT 出现「You」这类大写角色标签

#### Scenario: 助手消息靠左带头像

- **WHEN** 助手回复一条文本消息
- **THEN** 该消息贴在消息区左侧，agent 头像在最左、气泡在右；MUST NOT 出现「Assistant」这类大写角色标签，MUST NOT 在气泡上方画发言者名字

#### Scenario: 流式消息与落定消息同一侧

- **WHEN** 助手正在流式输出，随后该轮落定
- **THEN** 流式气泡与落定的助手气泡都在左侧、都带同一个 agent 头像，不出现「流式时在一侧、落定后换到另一侧」

#### Scenario: agent 头像优先用模板上传图

- **WHEN** 当前会话的模板设置了 `avatar_path` 且图片可读
- **THEN** 助手气泡与流式气泡都显示这张图，且 `<img>` 的 `src` 是以 `data:` 开头的 data URL（不是盘符路径）；清除该模板头像后显示由会话 id 生成的身份图案

#### Scenario: 上传头像真的显示出来

- **WHEN** 会话模板设置了头像，且核心的 `attachment.read` 返回该图片的 base64
- **THEN** 头像 `<img>` 实际可解码、可见（尺寸等于头像令牌值），`data-avatar-source="upload"`；MUST NOT 出现空图片框或破图

#### Scenario: 会话改名不换头像

- **WHEN** 用户给一个会话改名（会话 id 不变）
- **THEN** 助手侧的身份图案与改名前一模一样

#### Scenario: 头像图片丢失回落身份图案

- **WHEN** 模板的 `avatar_path` 指向的文件已被删除
- **THEN** 助手气泡显示身份图案，`data-avatar-source="identicon"` 可在 DOM 上读到，消息正文与附件照常渲染且没有错误横幅

#### Scenario: 附件与提示行不变

- **WHEN** 用户消息带图片附件，且模板未声明 image 模态（或附件文件缺失）
- **THEN** 气泡里仍有附件缩略图与「图片未发送」/「图片已丢失」提示行，文案与改气泡前逐字一致

#### Scenario: live 与 history 渲染同一形态

- **WHEN** 同一条用户消息分别经 live 事件与历史分页加载渲染
- **THEN** 两次都是右侧绿气泡 + 右端头像，不出现「live 是气泡、history 是旧卡片」的分叉

#### Scenario: 气泡尺寸与颜色取自令牌

- **WHEN** 审查单聊气泡与头像的样式
- **THEN** 头像尺寸、状态色、气泡底色与圆角都取自集中令牌或既有类名，组件里没有裸十六进制色值与任意间距数字

### Requirement: 单聊头部不承载管理入口

web 单聊聊天屏（`ChatScreen`）的头部 SHALL 只承载身份与状态信息（标题、token 计量、连接状态），MUST NOT 渲染 Provider / 模板等管理入口按钮。管理入口 SHALL 由应用壳层左栏底部的全局设置菜单提供（见 `web-management-ui` 的「全局设置菜单（左栏底部唯一管理入口）」），单聊与群聊共用同一个入口。

#### Scenario: 单聊头部不出现管理按钮

- **WHEN** 用户打开任意单聊
- **THEN** 头部不出现 `Providers` / 「模板」按钮（`data-testid="open-providers"` 与 `open-templates` 在页面上不存在），标题、token 计量与连接状态照常渲染；单聊主区（含头部）没有其它打开 Provider / 模板管理页的控件，管理页仍可从左栏底部「设置」菜单打开

### Requirement: 单聊头部工作路径与切换

web 单聊主区头部 SHALL 在**当前会话标题附近**显示该会话的工作路径，并提供切换入口。显示内容 SHALL 是 `session.list` 返回的 `workspace`：非空时逐字显示该设置值；为 `null` 时显示缺省说明（「缺省（应用主目录）」，逐字文案见文档 `界面文案（web）` 行）。长路径 SHALL 单行截断且 MUST NOT 撑破头部；截断时必须能用鼠标悬停看到全文（`title`）。

点击切换 SHALL 打开**文件夹选择对话框**（应用内的浏览框，数据源是核心的 `workspace.listDirs`）：框内 SHALL 有**可编辑的路径地址栏**（单行输入，值等于当前显示的文件夹，`title` 为全文）、当前目录的**子文件夹列表**、「上级」、可点回上层的面包屑、「跳转」、「选择此目录」与「取消」。地址栏 SHALL 与显示的文件夹双向对应：点文件夹 / 「上级」/ 面包屑 / 跳转成功后 SHALL 同步成新目录；用户在地址栏改路径后按 Enter 或点「跳转」SHALL 用该路径调 `workspace.listDirs` 校验。路径合法 SHALL 导航到该目录（列表 / 面包屑 / 地址栏一起更新）；点文件夹 SHALL 进入该子目录并重新列举；「上级」与面包屑 SHALL 回退并重新列举；路径非法 SHALL 在框内就地显示含路径与原因的错误、MUST NOT 导航、MUST NOT 发任何写 RPC，并让地址栏回到当前文件夹（地址栏与显示的文件夹始终对应）。浏览（点选）SHALL 仍是主交互，地址栏是辅助入口（MUST NOT 只剩文本输入）。对话框高度 SHALL **固定**为视口约 70%（`dvh` 视口占比），MUST NOT 随子文件夹数量变化（换文件夹时框高 MUST NOT 跳变）；子文件夹很多时 SHALL 在框内列表里滚动而不是把框撑高，整体保持紧凑居中。面包屑顶层 SHALL 是「此电脑」（Windows）：盘符根（如 `C:\`）的「上级」SHALL 回到「此电脑」并列出各盘（`C:` / `D:`…），点盘 SHALL 进入该盘根目录；「此电脑」不是真实目录，停在该层时「选择此目录」MUST 禁用并给出可读原因。POSIX 根不造「此电脑」层。对话框 MUST NOT 打开系统文件夹对话框、MUST NOT 整页跳转。打开时的起点 SHALL 是当前会话的 `workspace`；未设置时 SHALL 省略 `path`（起点由核心取应用主目录）。

确认 SHALL 调用 `session.setWorkspace`，payload 必须带 `sessionId` 与框内当前目录路径；成功后用返回的 `{session}` 更新会话列表里那一行（工作路径立即反映新值）并关闭对话框，MUST NOT 改变当前选中会话、消息列表、滚动位置、上下文快照与计量。「取消」MUST NOT 发出任何写 RPC。失败（路径不存在 / 非目录 / 核心 busy 等）SHALL 在对话框内**就地**显示可归因错误文本、保持对话框打开、保持已保存路径的显示不变；MUST NOT 只显示「保存失败」而不带原因。

没有选中会话（空聊天屏）时 MUST NOT 渲染该控件；群聊主区 MUST NOT 渲染该控件（群的工作路径在群视图右栏，见 `agent-group-chat` 的「web 组视图的群工作路径栏」）。组件 MUST NOT 自己连 WebSocket 或发 RPC：数据与动作由应用壳层注入；未注入切换回调时 MUST NOT 渲染该控件（既有注入式测试挂架与别的宿主不受影响）。

#### Scenario: 显示缺省工作路径

- **WHEN** 用户打开一个 `workspace = null` 的单聊
- **THEN** 标题旁显示「缺省（应用主目录）」与「切换」入口，不显示空串、不显示错误占位

#### Scenario: 显示自定义路径且长路径可看全文

- **WHEN** 用户打开一个设置了很长工作路径的单聊并点「切换」
- **THEN** 标题旁单行显示该路径且被截断（头部没有横向溢出 / 没有换行成多行），该元素的 `title` 是完整路径；对话框内的地址栏逐字显示同一完整路径（可编辑），且它是框内唯一的文本输入框；点进一个子目录后地址栏同步成该子目录的绝对路径

#### Scenario: 点选目录后保存走 session.setWorkspace

- **WHEN** 用户点「切换」，在文件夹选择框里点进一个子目录并点「选择此目录」
- **THEN** 客户端发出 `session.setWorkspace {sessionId, workspace: <该子目录的绝对路径>}`（payload 逐字可断言），成功后标题旁立刻显示新路径、对话框关闭，当前会话、消息、滚动与快照都不变；不发 `group.setWorkspace`、不整页刷新

#### Scenario: 对话框以会话工作路径为起点并可回退

- **WHEN** 用户打开一个已设置工作路径的单聊并点「切换」，然后进入子目录、再点「上级」
- **THEN** 首次列举请求带该会话的 `workspace`；进入子目录后框内当前路径变成子目录绝对路径并重新列举；「上级」回到上一层并重新列举；「取消」关闭对话框且不发出任何写 RPC

#### Scenario: 盘符根可回「此电脑」并切换其它盘

- **WHEN** Windows 上用户从 `C:\work` 打开文件夹选择框，点「上级」两次到 `C:\`，再点「上级」，然后点 `D:`
- **THEN** `C:\` 的「上级」仍可用；到「此电脑」后框内当前路径显示「此电脑」、列出 `C:` / `D:` 等盘符、面包屑顶层是「此电脑」；点 `D:` 进入 `D:\` 并重新列举；面包屑「此电脑」可点回盘符列表；「此电脑」层的「选择此目录」禁用并显示「不是目录」的原因，点它不发任何写 RPC

#### Scenario: 地址栏可编辑并与显示的文件夹同步

- **WHEN** 用户打开文件夹选择框，点进一个子目录，然后把地址栏改成另一个已存在的目录并按 Enter
- **THEN** 点进子目录后地址栏的值同步成该子目录的绝对路径；按 Enter 后客户端用地址栏路径调 `workspace.listDirs`，成功后列表 / 面包屑 / 地址栏都变成该目录，且不发 `session.setWorkspace`；点「跳转」与按 Enter 等价

#### Scenario: 地址栏输入非法路径就地报错且不跳

- **WHEN** 用户在地址栏输入一个不存在 / 不是目录的路径并按 Enter
- **THEN** 对话框内在列表位置显示含该路径与原因的错误，列表 / 面包屑 / 地址栏仍停在原目录（地址栏回到当前文件夹的值），对话框保持打开，不发任何写 RPC；页面无未捕获异常

#### Scenario: 对话框高度固定，换文件夹不跳变

- **WHEN** 用户打开一个含 40 个子文件夹的目录，点进一个没有子文件夹的叶子目录，再点「上级」回来
- **THEN** 三次测得的对话框高度相同（±1px），且等于视口约 70%（明显小于视口、垂直居中、底边不出视口）；子文件夹多时列表在框内滚动（列表 `scrollHeight > clientHeight`），空叶子时列表无滚动量；框内地址栏 / 面包屑 / 上级 / 两个按钮仍可见可用

#### Scenario: 未设置工作区时从应用主目录开始

- **WHEN** 用户打开一个 `workspace = null` 的单聊并点「切换」
- **THEN** 列举请求**省略** `path`，框内当前路径是核心返回的应用主目录，子文件夹列表来自 `workspace.listDirs`

#### Scenario: 失败就地可归因且不改已保存值

- **WHEN** 用户在文件夹选择框里选中一个核心拒绝的目录并点「选择此目录」，核心返回可归因错误
- **THEN** 对话框内显示该错误文本（含路径 / 原因），对话框保持打开，标题旁仍显示原来的已保存路径；页面上没有未捕获异常

#### Scenario: 切会话后显示各自路径

- **WHEN** 用户从一个设置了工作路径的单聊切到另一个未设置的会话
- **THEN** 头部工作路径立刻变成「缺省（应用主目录）」，MUST NOT 残留上一个会话的路径

#### Scenario: 空选中与群聊不渲染该控件

- **WHEN** 当前没有选中会话，或当前主区是群聊
- **THEN** 单聊头部的「工作路径」控件不存在（`data-testid` 节点数为 0）；群聊的工作路径只出现在群视图右栏的栏里

#### Scenario: 窄屏不溢出

- **WHEN** 浏览器宽度为产品既有的窄屏断点（720px），用户打开一个设置了长路径的单聊
- **THEN** 标题、路径与切换入口仍在头部内，页面没有横向滚动，控件不覆盖连接状态与连接徽标
