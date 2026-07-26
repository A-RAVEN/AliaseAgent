## Context

当前系统有 4 个工具 (read_file, list_dir, web_search, web_fetch)，全是 C++ FFI 调用。需要一个纯 Dart 的轻量工具让 AI 确认当前时间。

## Decisions

### D1: 纯 Dart 实现

不经过 sidecar FFI。`_executeTool` 中新增 case，直接调用 `DateTime.now().toIso8601String()`。无网络依赖，始终可用。

### D2: 输出格式

```json
{
  "ok": true,
  "datetime": "2026-07-21T01:30:00.000",
  "date": "2026-07-21",
  "time": "01:30:00",
  "timezone": "+08:00",
  "content": "Current time: 2026-07-21 01:30:00 +08:00"
}
```

`content` 字段是 AI 实际接收到的文本，其他字段供调试/日志使用。

### D3: 工具定义

```json
{
  "name": "get_current_time",
  "description": "Get the current date and time...",
  "input_schema": {
    "type": "object",
    "properties": {},
    "required": []
  }
}
```

无参数。始终返回成功。
