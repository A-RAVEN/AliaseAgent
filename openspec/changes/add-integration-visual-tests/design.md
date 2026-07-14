## Context

当前 `SidecarBridge` 是 `dart:ffi` 直接调用 C++ DLL 的单例。widget test 无法通过它驱动数据流——没有真实密钥、没有网络、没有 DLL。`add-widget-interaction-tests` 已通过 Fake repo 覆盖到 Repository 层，但消息发送→SSE 回调→状态更新的完整链路仍无法测试。

需要提取 `ISidecar` 接口，创建 `FakeSidecar` 实现，注入到 `ChatScreen`，使 integration test 能控制整个数据流。

## Goals / Non-Goals

**Goals:**
- 提取 `ISidecar` 接口（`sendMessage()` + `setWorkspace()` + `readFile()` + `listDir()`）
- `SidecarBridge` 实现接口（行为不变）
- `FakeSidecar` 返回预设 SSE 事件序列（message / tool_call / thinking / done）及工具执行结果
- `ChatScreen` 接受可选 `ISidecar?`，默认 `SidecarBridge.instance`
- Integration test 覆盖：发送消息→收到回复、tool call 流程、error 传播、stop_reason、streaming 状态
- 每个 test scenario 自动截图 → `references/` baseline → 后续 diff
- `FakeSidecar` 可编程：`queueChunk(text)` / `queueToolCall(name, input)` / `queueThinking(json)` / `queueDone({code, error, stopReason})`

**Non-Goals:**
- 不改 SidecarBridge 内部 FFI 调用逻辑
- 不做真实 API 调用的集成测试
- 不替换 `ConfigService` 或 `DatabaseService`（已有 fake repo）

## Decisions

### D1: 接口抽象层次

```dart
abstract class ISidecar {
  Future<void> sendMessage({
    required String apiKey,
    required String baseUrl,
    required String model,
    required String systemPrompt,
    required String messagesJson,
    required String toolsJson,
    required OnChunkCallback onChunk,
    required OnToolCallCallback onToolCall,
    OnThinkingCallback? onThinking,
    required OnDoneCallback onDone,
  });
  void setWorkspace(String path);
  String readFile(String path);
  String listDir(String path);
}
```

**选择**: 精确匹配 `SidecarBridge` 的 4 个 public 方法签名。`readFile()` / `listDir()` 必须包含在接口中——`_executeTool()` 直接调用它们，FakeSidecar 需返回可控的 JSON 工具结果。

### D2: FakeSidecar 事件队列

```dart
class FakeSidecar implements ISidecar {
  final List<FakeEvent> _events = [];
  String? _readFileResult;
  String? _listDirResult;
  
  void queueChunk(String text);
  void queueToolCall(String json);
  void queueThinking(String json);
  void queueDone({int code = 0, String? error, String? stopReason});
  
  // Tool execution: set fake results for readFile/listDir
  void stubReadFile(String resultJson);
  void stubListDir(String resultJson);
  
  @override
  Future<void> sendMessage(...) async {
    // 按序回放所有排队事件，调用对应 callback
  }
  
  @override
  String readFile(String path) => _readFileResult ?? '{"ok":true,"content":"fake content"}';
  
  @override
  String listDir(String path) => _listDirResult ?? '{"ok":true,"entries":[]}';
}
```

**选择**: Queue + replay 模式。Test setup 时预设事件序列，`sendMessage()` 被调用时按序回放。`queueDone()` 统一处理正常结束和错误——通过 `{code, error, stopReason}` 三参数映射真实 `onDone` 回调签名。

**选择**: Queue + replay 模式。Test setup 时预设事件序列，`sendMessage()` 被调用时按序回放。
**替代方案**: Stream controller 模式 → 需要管理背压，对测试过度设计。

### D3: 截图策略（Flutter RepaintBoundary.toImage）

使用 Flutter 内置 `RenderRepaintBoundary.toImage()` + `toByteData(format: ImageByteFormat.png)` 直接从 Widget 树渲染截图——纯内存操作，不依赖窗口/桌面/外部截图工具。

```dart
Future<void> captureWidgetAsPng(GlobalKey key, String path) async {
  final boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
  final image = await boundary!.toImage(pixelRatio: 1.0);
  final byteData = await image.toByteData(format: ImageByteFormat.png);
  await File(path).writeAsBytes(byteData!.buffer.asUint8List());
}
```

Integration test 中：外层包 `RepaintBoundary(key: _screenshotKey)` → 渲染完成后调 `captureWidgetAsPng` → PNG 存入 `test/smoke/output/`。

**选择**: Flutter 内置 API。零外部依赖，所有平台可用，不受桌面环境影响。
**替代方案**: PowerShell `CopyFromScreen` — 截全屏含桌面其他窗口，像素 diff 不可靠；从 Dart `Process.run('bash')` 调用需要 Git Bash 在 PATH，不可移植。

### D4: Baseline 机制

```
首次运行:  references/ 为空 → 截图保存为 baseline → 报告 "BASELINE_CREATED"
后续运行:  references/ 存在 → 截图存 output/ → 逐文件 SHA256 hash 对比 → 报告 pass/fail
```

Diff 用文件 hash（`sha256sum`）做精确对比——PNG 像素级变化必然改变 hash。`run_all.sh` step 5：逐个对比 `output/*.png` vs `references/*.png` hash。

## Risks / Trade-offs

- **[R] FakeSidecar 事件时序与真实场景不同** → Mitigation: `sendMessage` 立即回放而非模拟网络延迟。需要时序相关测试时加 `queueDelay(ms)`。
- **[R] RepaintBoundary 截图与真实渲染有差异** → Mitigation: `toImage()` 捕获的是 GPU 渲染后的像素输出，与屏幕显示一致。仅在包含 platform view 或 shader 特效时有差异（AliasAgent 未使用）。
- **[R] ISidecar 接口变化时 FakeSidecar 需同步更新** → `implements ISidecar` 在编译期强制签名一致。
