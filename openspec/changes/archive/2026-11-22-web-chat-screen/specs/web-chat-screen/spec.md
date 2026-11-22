## ADDED Requirements

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