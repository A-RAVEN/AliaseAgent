# Proposal: AliasAgent — 通用 AI 编程 Agent 框架

## 动机

现有 AI 编程助手（以 Claude Code 为代表）存在以下不足：

1. **交互界面简陋** — CLI 界面不友好，Markdown 渲染体验差
2. **多 Agent 支持薄弱** — 多 Agent 协作仍处于实验阶段
3. **文档支持有限** — 对 docx、PDF 等复杂文档格式缺乏原生支持
4. **工作空间受限** — 仅限单一文件夹，缺乏多项目/多根工作空间感知
5. **模型供应商单一** — 默认仅支持单一模型供应商，无法灵活切换和组合多个 AI 模型
6. **跨平台缺失** — 无法在移动端或不同设备间无缝同步对话

## 目标

构建一个通用的、可扩展的 AI Agent 编程框架，具备：

- 现代化的独立应用交互界面，支持桌面端和移动端
- 类似微信/QQ 的实时多平台对话体验
- 灵活的多模型接入和路由能力
- 深度文件系统集成和复杂文档处理
- 强大的多 Agent 编排引擎

## 已确定架构决策

| 维度 | 决策 | 说明 |
|------|------|------|
| 交互层 | Flutter 独立应用 | 一套代码覆盖桌面 + 移动端 |
| Agent 执行 | PC 本地执行 | 代码操作在 PC，移动端仅对话 |
| Sidecar | C++ via FFI | 系统能力层，Flutter 通过 dart:ffi 调用 |
| 服务端 | 轻量消息中继 | 仅负责消息同步和会话存储 |
| 模型策略 | Agent Type 一等公民 | 每个 Agent Type 独立指定 provider/model/api/context/tools/system prompt，不设全局模型 |
| 交互模式 | 手动选择 + 自动编排 | 手动指定当前回复的 Agent Type，也支持 Agent 流水线自动协作 |
| 文档解析 | DocWire SDK（优先） | C++20 原生，支持 docx/pdf/pptx/xlsx 等 100+ 格式，内置 OCR 和 AI 管道 |
| 文档解析备选 | DuckX + PDFium | MIT + BSD 许可，各司其职，成熟稳定 |
| Agent 类型体系 | Regular + Sub 两级 | Regular 持久有上下文、用户对话；Sub 临时无上下文、用完销毁、只读工具 |
| 编排容器 | 群聊（Group Chat） | 群 = 编排容器，创建时选择模式并配置 Agent 实例 |
| 编排模式 | Pipeline / Fan-out / Debate / Dynamic | Pipeline 顺序流、Fan-out 分发聚合、Debate 辩论裁决、Dynamic Planner 自主 |
| 用户角色 | 参与者 | 每步产出后可评论、纠正、放行，非旁观者 |

## 待探讨

- 多根工作空间设计
- Sidecar 内部模块详细设计
- 移动端功能边界
- 会话持久化与跨设备同步细节

## 非目标（本期）

- 支持所有编程语言生态（先聚焦通用框架）
- 完整的 IDE 级别代码编辑能力
- 第三方插件市场
