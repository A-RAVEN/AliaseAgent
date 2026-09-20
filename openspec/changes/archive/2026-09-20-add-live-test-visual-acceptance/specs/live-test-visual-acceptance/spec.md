## ADDED Requirements

### Requirement: Live test end-of-case screenshot capture
窗口版 live 测试（真实模型驱动，`-d windows` 真实桌面包）SHALL 在**每个用例**用 `RepaintBoundary.toImage()` 捕获当前 **Flutter 场景渲染**为 PNG（非 OS 窗口像素——不含标题栏/边框/OS 滚动条；`pixelRatio: 1.0` 在 Windows 高缩放下为逻辑像素，异于 CopyFromScreen 物理像素，见语义澄清），存入独立目录 `test/live_visual/`。捕获 SHALL 在测试侧包裹 `RepaintBoundary`（不经 `lib/` 生产代码），复用现有 `captureWidgetAsPng` 或轻量封装；捕获失败 SHALL 记录日志但**不得**使测试失败（截图是可观测增强，非断言）。

#### Scenario: 单用例成功路径截图
- **WHEN** 一个 live 用例（如 `real_api_test` 3.1）完成真实模型回复并渲染
- **THEN** 测试在 teardown 前把该 Flutter 场景捕获为 `test/live_visual/<用例名>.png`
- **AND** 该 PNG 能反映 Flutter 场景渲染（回答气泡正确绘制，非黑/空白/裁剪帧）

#### Scenario: 用例失败时仍尝试截图
- **WHEN** 一个 live 用例抛出断言失败、超时、或静默完成（诚实 fail）
- **THEN** 该用例在 `fail()` 抛出前（try/finally 或 pre-fail capture）仍尝试截图
- **AND** 若截图成功则产出 `<用例名>.png`（呈现失败态画面）；若失败则记录日志、不阻断
- **AND** 既有断言与 fail 行为完全不受影响

#### Scenario: 截图失败不阻断测试
- **WHEN** 用例截图时 `toImage` 抛错或写盘失败
- **THEN** 该失败被 try/catch（或等效）吸收并记录日志，**不** `fail` 测试
- **AND** 用例本身原有的断言逻辑不受影响

#### Scenario: 截图非空白校验且不留 stale 文件
- **WHEN** 用例截图写入 `test/live_visual/<用例名>.png`
- **THEN** 该 PNG SHALL 通过非空白/非空校验（字节数/尺寸阈值），否则视为失败
- **AND** 捕获失败时 SHALL **删除**目标文件——不得留下上一轮旧的 `<用例名>.png`（stale）被误读为当前轮

#### Scenario: 输出目录隔离
- **WHEN** 用例截图写入 `test/live_visual/`
- **THEN** 该目录与 `test/smoke/output/`（FakeSidecar 像素回归基线）隔离
- **AND** `test/live_visual/` SHALL 被 `.gitignore` 忽略，截图不入库

### Requirement: Native-vision visual acceptance by main loop
主循环（Claude）SHALL 用**原生视觉**（`Read` 工具直读 PNG，非任何 MCP 工具）逐张读 live 截图做**判断式视觉效果验收**（judgment-based），按明确清单核实界面元素；清单项需真实渲染才可通过，看不清/异常/截图无效 SHALL 如实记为失败或异常，**不得伪造通过**。验收 SHALL 锚定**结构线索 + 量化阈值**（下辖场景用 ≥N 字符、空白占比 < 阈值、done 状态 + 非空结果预览等），而**不比对真实模型的非确定性文本**——否则同用例两次 run 因文本不同而结论不同，验收不可复现、不可审计。本验收为**判断式**，不等于像素哈希回归（后者归 `visual-regression` spec）。

#### Scenario: Answer bubble rendered
- **WHEN** 主循环读取某用例的截图
- **THEN** 主循环核实存在一个**非流式** assistant MessageBubble、文本长度 **≥ 设定下限**（如 ≥20 字符）、非空白、非 "Error:" 开头——用**结构线索 + 量化阈值**判定，**不比对真实模型的非确定文本**（每次回复文本/长度/工具选择都变，文本匹配不可判）
- **AND** 若气泡缺失/空白/低于阈值/为 Error: 开头，主循环如实报告该图异常而非通过

#### Scenario: Tool card rendered with result
- **WHEN** 用例涉及工具调用且在截图中出现 `ToolCallCard`
- **THEN** 主循环核实工具卡状态为 done 且能看到工具名与结果预览
- **AND** 若工具卡缺失或状态非预期，主循环如实报告

#### Scenario: Layout sanity
- **WHEN** 主循环读取截图
- **THEN** 主循环核实布局正常（左侧会话边栏 + 右侧聊天区），无黄黑 overflow 横幅、无裁切、**异常空白/黑块占比低于阈值**（如整图 <30%）、侧边栏宽度在合理区间
- **AND** 若有布局异常，主循环如实报告

#### Scenario: Acceptance report is honest
- **WHEN** 主循环完成对该用例截图的验收
- **THEN** 报告输出该用例的通过/异常/截图无效三态之一，并附具体观察
- **AND** 不得为得出"通过"而依赖未经证实的推测或隐藏异常

### Requirement: Spike-first validation gate
live 截图**可变更** SHALL 先经 Spike 验证：先在**单个用例**（`real_api_test` 3.1）上确认 `RepaintBoundary.toImage()` 在真实 live 窗口能稳定出真图（非黑/空白/裁剪、且主循环能读出内容），**成功后才**铺满其余用例；Spike 失败 SHALL 触发 design 决策点（切换 PowerShell `CopyFromScreen` 方案）而非继续假设 `toImage` 可行。

#### Scenario: Spike produces a valid image
- **WHEN** 单用例（3.1）结尾运行 Spike 截图
- **THEN** 产出 `test/live_visual/3.1_basic.png` 且主循环能从中读到回答答复内容
- **AND** 该结果为 gating：**Spike 通过 SHALL 先停下向用户报告结果并交回 go/no-go，用户确认"继续"后才**铺满其余用例（非自动继续——Spike 是可行性证明 + 用户确认点，见 design D2 返工 #11）

#### Scenario: Spike fails and triggers fallback
- **WHEN** Spike 截图得到黑帧/空白/`toImage` 抛错，主循环无法从中读出内容
- **THEN** 记录 Spike 失败，**不**铺满其余用例
- **AND** 按 design 决策点切换到 PowerShell `CopyFromScreen` 方案并更新 artifacts
