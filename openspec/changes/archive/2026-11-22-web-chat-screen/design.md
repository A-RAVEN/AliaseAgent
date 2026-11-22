## Context

`web-ui-core-shim` 已落：无头核心 + WS/JSON-RPC + 事件序列化 + `message.query` 游标分页接口 + 最小验证页（`web/src/App.tsx`、`protocol.ts` 的 `RpcClient`）。本 change 把最小页扩成完整聊天屏。

**对抗审查核实的现状事实（产生状态的代码已追）**：
1. **分页接口缺口（比初稿自述更大）**：`message_page.dart queryPageBySession` 只有 `afterSeq`（`seq > ?` + `ORDER BY seq ASC` + limit），`_handleMessageQuery` 把 cursor 映射 afterSeq。**首屏不传 cursor 拿到的是最旧页**；无 beforeSeq/降序/尾锚，`serializeSession` 无 messageCount/lastSeq。聊天屏要"打开即在最新页 + 上翻加载更早"，现接口两者都做不到。`nextCursor`=升序页末条 seq，是**前向**游标，初稿"用 nextCursor 反向"是语义错误。
2. **live 与 history 的 toolCalls 形状分叉**：中间助手消息在工具执行**前**落库并发 `onAssistantMessage(false)`（toolCalls 是原始 `{type,id,name,input}`，无 toolName/status/result）；工具执行后 `_deliverToolResult` 原位 `addAll(activity.toJson())` 富化并 `updateToolCalls` 写库，**富化后不再发 assistant.message**。故 live 中间消息 toolCalls 是原始形状、history 是富化形状。thinking 同理（live 带 index，history 去 index）。
3. **最终消息聚合整轮工具**：最终分支 `toolCallsJson = jsonEncode(allTurnToolCalls)`（整轮所有调用的并集，与各中间消息重叠）；`serializeMessage` 无 isFinal 键。按"每条消息 toolCalls 都内联渲染"会**重复渲染工具卡**。
4. **流式时序**：`turn.completed` 是**每次 API 请求**结束就发（非整轮）；整轮流式态由 `agent.streaming` 标记。每条 `assistant.message`（含中间轮 isFinal=false）都带该轮已流式完的文本。
5. **重连恢复**：RPC 面固定 `[core.ping, session.list, message.query, agent.send, agent.cancel]`，**无 ensure/subscribe 方法**；`_broadcast` 实时遍历当前 `_clients`，事件天然到达重连后的新连接。恢复靠"重拉当前页 + 广播到当前订阅者"，不需要 ensure。`_handlePing` 无条件同步回 ok（心跳超时状态真实核心无产生者，测试需假对端）。
6. 空气泡实测（known-bugs）：某会话 62 条助手消息 56 条空正文。`RpcClient.onclose` 只置 closed 拒在途、无重连。

约束：不发明上下限魔数（行为阈值须有出处或可配）；砍内容可见可恢复（折叠≠丢弃、多工具折叠须有计数标记）；用户可见输出简体中文；design-system 方法论先定约束再写组件、design_audit 验收。

## Goals / Non-Goals

**Goals:**
- 修空气泡：工具轮渲染成折叠工具卡（每 toolCall 一张单行卡），真回复露出；live 与 history 经归一/合并/去重后一致。
- F-002 工具/思考卡默认折叠、折叠态严格单行；F-003 贴底跟随；F-004 跳底按钮。
- 会话列表虚拟滚动；消息分页**首屏锚定最新页 + 上翻加载更早**；WS 自动重连 + 心跳。
- 设计 tokens 先行 + design_audit 渲染审计。

**Non-Goals:**
- 不碰 agent 业务逻辑/压缩/技能等核心行为；不做 restore/_history 内存边界（规模 change）；不迁核心 TS；不做原生壳；不修 F-001。
- message.query 查询接口的 additive 扩展（尾锚+反向游标）是聊天屏正常实现所需，属查询面增量能力，不碰 agent 行为，给 web-core-shim 分页 requirement 补 MODIFIED delta。

## Decisions

> **授权口径**：下列 D1~D13 为技术实现决策（与 proposal P1~P7 对应，编号独立避免混淆）。用户已拍板的需求：F-002~004 并入新 web 界面（2026-11-16）、空气泡修复 + 自动重连并入本 change（2026-11-21）、路线 C/取消 A。具体技术选型（配色/字阶/虚拟滚动库/重连参数默认值）由实现按常理与产品先例定、文档化，不拿助手自造的约束去要求用户拍板。

### 设计系统（design-system 方法论，先定约束）

- **D1 方向**：「dense operator console，近黑 slate 表面，单一 sky 信号色」。延续最小页暗色方向并收敛，不另起平行体系、不用 violet/indigo 渐变。
- **D2 调色板**（一条中性 ramp + 一个 accent + 按需语义色，全进 tokens，组件禁裸 hex）：中性 ramp（同 hue slate，沿用 #0b0f19 起）bg `#0b0f19` / surface `#111726` / surface-2 `#1b2333` / border `#2a3346` / text-muted `#8b93a7` / text `#e6e9ef`；accent sky `#38bdf8`（仅主操作"发送"与贴底/链接等"act here"，不作装饰）；语义 success `#34d399` / warning `#fbbf24` / danger `#f87171`（仅工具状态/错误/技能失败）。
- **D3 字阶**（混合派生，如实声明）：低三档 12/14/16 沿用最小页既有 Tailwind 档（text-xs/sm/base），上两档 20/25 从 16 按 1.25 延伸；只用这五档、禁中间号。正文 16px 行高 1.5；**12px 仅限元信息标签**（须读内容≥14px），该例外由组件测试钉住（12px 只出现在元信息 testid）+ 审计核。一族字体（system-ui + Microsoft YaHei 栈）两权重 400/600。
- **D4 间距 scale**：4/8/12/16/24/32/48/64（design-system 方法论原文 scale），所有 padding/margin/gap 取自此，禁任意值。
- **D5 组件约束**：单圆角 8px（大表面 12px 一档）；两级 elevation；边框单色 border；图标单一集合 lucide-react（禁 emoji 当图标；ChevronDown 等导出名 apply 装包后核 README）。
- **D6 状态**：空会话/空消息/加载中/错误/超长内容/断线重连中都有明确态。

### 渲染（修空气泡 + F-002 + live/history 一致）

- **D7 统一渲染 + 归一/合并/去重**：
  - 抽 `renderMessages` 纯函数，live 与 history 共用。但**纯函数之前须先归一**（审查 C2/C3/C4）：
  - **工具事件按 id 合并**：live 的 tool.call/tool.result 按 activity.id 合并进对应消息的 toolCalls（name→toolName 归一、补 status/result/resultPreview）；history 的 toolCalls 已富化直接用。ToolCallActivity.fromJson 已有 `toolName ?? name`、status 缺省 executing 先例可参照。
  - **去重**：最终消息的聚合 toolCalls（allTurnToolCalls 并集）与中间消息重叠——**按 tool id 去重**，或"中间消息渲染其 toolCalls、最终消息只渲染正文不渲染聚合 toolCalls"。取后者更简（最终消息=纯回复气泡），避免重复卡。
  - **thinking 归一**：live thinking.delta/block 按 index 累积，history thinkingJson 块按数组位置派生 index，统一形状。
  - **空正文工具轮消息**（content 空、toolCalls 非空）→ 不产生独立气泡，**每个 toolCall 渲染一张单行折叠卡**（多工具消息=多张单行卡，不是一张大卡只露一个工具；审查 RS-04）。
  - **非空正文助手消息** → Markdown 正文气泡 + 其 toolCalls/thinking 内联折叠卡（去重后）。
  - 工具卡/思考卡**默认折叠、折叠态严格单行**（truncate + 固定行高=正文行高 24px）；点击展开全文（可滚，折叠≠丢弃）。
- **D8 流式语义（审查 C4 修正）**：**每条 assistant.message（含中间轮 isFinal=false）都落定当轮流式文本**（清 streamingText、追加该轮气泡）；assistant.chunk 累积进 streamingText。**整轮流式态以 agent.streaming 为准**（turn.completed 是每次 API 请求结束，不用它判整轮"正在生成"）。工具执行期间整轮仍 streaming=true。

### 滚动（F-003/F-004）

- **D9 贴底跟随 + 跳底**：贴底判定 `scrollTop + clientHeight >= scrollHeight - bottomThreshold`，bottomThreshold=24px（出处：D4 scale 步长，且=正文行高 16×1.5；本机 DSH 同类阈值 25px 佐证相邻合理；落 token + 可配 + 审计核）。贴底新内容自动滚到底；上翻非贴底停跟随。跳底按钮：非贴底显示、点击滚到底恢复跟随、贴底隐藏；**位置输入框上方右对齐**（审查 G：本机 DSH toBottomSlot 是 justify-content:flex-end 右对齐，初稿"居中"是助手加的，撤回）；圆形 chevron-down（lucide）。**未读标记**：DSH 当前实现也无 badge，用户原话"类似于"留裁量——**首版不做未读标记，显式声明为 deliberate 简化**（待拍板可加）。

### 分页（审查 RS-01/EXT-01/C1 修正，必要 additive 扩展）

- **D10 message.query additive 扩展 + 首屏尾锚**：
  - 核心 `queryPageBySession` 增**反向游标 beforeSeq**（`seq < ?` + `ORDER BY seq DESC` + limit，返回再反转为升序）与**尾锚模式**（不传游标时取**最新一页**：`ORDER BY seq DESC limit pageSize` 再反转）。返回增 `prevCursor`（本页首条 seq，指向更早页）；保留既有 afterSeq/nextCursor 前向语义不变（Flutter 不受影响）。
  - RPC `message.query` 增参数 `before`（反向游标）与 `anchor: 'tail'|'head'`（缺省 tail=最新页）；pageSize 仍请求方必填。
  - UI：首屏 anchor=tail 取最新一页；上翻到顶用 prevCursor 加载更早一页，保持滚动位置不跳。
  - **给 web-core-shim「会话与消息查询支持分页」补 MODIFIED delta**（additive：尾锚 + beforeSeq + prevCursor，保留前向兼容）。这是本 change 唯一触及核心处，additive 不改 agent 行为。

### 虚拟滚动 / 重连

- **D11 虚拟滚动**：会话列表虚拟化（数百~数千只渲染可视区）；消息列表动态高度虚拟化（工具卡折叠/展开高度变化须测量）。库选型 Open Question（倾向 @tanstack/react-virtual，**本地无据标未验证**，apply 装包后核 README/体积再定）。虚拟列表与贴底跟随/上翻加载的相互作用须交互测试核（动态高度 scrollToBottom/保持位置）。
- **D12 重连 + 心跳（审查 RS-03/A/D 修正）**：RpcClient 指数退避自动重连 + 心跳（周期发 core.ping，**超时未回判死**触发重连）。四参数落 tokens 可配常量 + 用户文档键表（配置项出处分支：默认值+范围+键表）：退避 base=1s（产品先例 kimi_search 429 重试 1s 起步）、cap=30s、心跳周期=15s、心跳超时=5s（后三者助手定的默认，可配、文档化，不裸写隐藏魔数）。重连成功**重拉当前页消息恢复状态 + 依赖 _broadcast 到当前订阅者**（不写"重新 ensure"，无此 RPC）；重连中明确态。断线期事件无重放缓冲（披露项，spec 不承诺重放）。
- **D13 测试通道（审查 TC-1/TC-6/EXT-06 修正）**：**布局/滚动断言（折叠单行高度、贴底跟随、上翻不打扰、跳底）走 puppeteer 真实渲染**（仓库已有 headless Edge 先例 smoke.mjs；jsdom 无布局引擎 getBoundingClientRect 恒 0，测不了高度/滚动）。纯逻辑（renderMessages 归一/去重、protocol 重连状态机）可用 vitest 单测。**心跳超时用例需假 WS 对端**（接受连接但不回 ping；ws@8.23.0 已在盘上）。design_audit 只测初态（文本尺寸/颜色/对比度/间距/控件），**不测折叠单行高度/展开态/非贴底态**——那些由 puppeteer 交互测试兜底（审查 TC-7：撤回"审计核单行高度"的委托）。

## Risks / Trade-offs

- **[message.query 扩展触及核心]** → additive（尾锚+beforeSeq+prevCursor，保留前向兼容），不改 agent 行为；给 web-core-shim 分页 requirement 补 MODIFIED delta + 核心测试；Flutter 仍用前向不受影响。
- **[live/history 归一复杂]** → 按 id 合并 tool 事件 + name 归一 + 最终消息只渲染正文（去重）+ thinking index 归一；组件测试覆盖两路径同形状。
- **[折叠单行高度测不了（jsdom）]** → 布局/滚动断言走 puppeteer 真实渲染；design_audit 不背此验收。
- **[虚拟滚动动态高度与贴底/上翻冲突]** → 交互测试核 scrollToBottom/保持位置/上翻加载；库选型装包后核。
- **[重连参数魔数]** → 四参数（base=1s/cap=30s/周期=15s/超时=5s）落可配 tokens + 文档键表（配置项出处分支），base 有 kimi_search 先例，其余助手定的默认可配。
- **[旧文档守卫锚点 '最小验证页' 失效]** → 文档更新同步改 web_core_docs_test.dart 锚点集（显式任务，审查 TC-2）。
- **[smoke.mjs 手动滚底掏空贴底断言]** → 完整屏 live 驱动移除/条件化手动滚底步 + report 增滚动度量（审查 TC-5）。
- **[多工具折叠粒度]** → 每 toolCall 一张单行卡（不是一卡露一个），折叠态可见性达标。
- **[design_audit 漂移]** → tokens 集中、禁裸 hex/任意间距；审计逐条修，deliberate 例外（12px 元信息、未读标记不做）显式说明。

## Migration Plan

1. 先定 tokens（D2~D6）+ **message.query additive 扩展**（D10，核心 + web-core-shim delta + 测试）。
2. renderMessages 归一/合并/去重 + 工具/思考折叠卡（D7/D8），修空气泡，组件测试（vitest 逻辑 + puppeteer 布局）。
3. 滚动跟随 + 跳底（D9）+ 虚拟滚动（D11）+ 分页落地（D10）。
4. RpcClient 重连 + 心跳（D12，假对端测超时）。
5. design_audit 初态审计 + puppeteer 交互验收 + live 无头浏览器截图视觉验收。
6. 回退：web 独立子项目，回退=恢复最小页 App.tsx（git）；message.query 扩展 additive 兼容，回退不影响 Flutter。

## Open Questions

- **虚拟滚动库**：@tanstack/react-virtual vs 手写窗口化（本地无据，apply 装包后核 README/体积/动态高度 API 再定）。
- **重连/心跳四参数默认值**：base=1s（kimi_search 先例）/cap=30s/周期=15s/超时=5s，落可配 tokens + 文档键表（配置项出处分支），不拿自造约束要求用户拍板。
- **bottomThreshold=24px**：取间距 scale 步长=正文行高，审计确认。
- **未读标记**：首版不做（deliberate 简化），待拍板可加。

## 已裁决（对抗审查后关闭）

- **分页首屏锚定**：必须尾锚（最新页）+ 反向游标，additive 扩 message.query（原 Open Question"向前翻页"升级为明确决策 D10，补 web-core-shim delta）。
- **重连恢复措辞**：重拉当前页 + 广播到当前订阅者（删"重新 ensure"，无此 RPC）。
- **跳底按钮位置**：右对齐参照 DSH（撤回"居中"）；未读标记首版不做显式声明。
- **单行高度验收通道**：puppeteer 真实渲染（jsdom 测不了；design_audit 不测此项）。