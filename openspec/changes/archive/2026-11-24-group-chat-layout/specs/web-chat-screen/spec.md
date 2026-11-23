## ADDED Requirements

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
