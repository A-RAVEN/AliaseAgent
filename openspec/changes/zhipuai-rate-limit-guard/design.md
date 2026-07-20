## Context

AI 可以在同轮对话中发出多个 `web_search` tool call，每个都可以指定 `providers:["zhipuai"]`。`_executeTool` 的 for 循环是 `await` 串行的，但请求间无任何间隔。成功请求需要 1-2 秒（curl + 网络 RTT），这个天然间隔通常足够。但一旦遇到 429（200ms 返回），下一个请求在 2ms 后就发出，形成轰炸模式，触发 ZhipuAI 升级限流策略（429 → 400 内容审核拦截）。

## Decisions

### D1: Provider-level mutex lock

```
search() 入口:
  lock(mutex_)
  // 同一时刻只有一个线程在执行 ZhipuAI HTTP 请求
  // ... 原有逻辑 ...
  unlock(mutex_)  // RAII: lock_guard
```

Static `std::mutex`，存在 `zhipuai_search.cpp` 全局作用域。保护整个 `search()` 调用周期（包括 curl 请求 + 解析），跨 worker isolate 生效（同一 DLL 同一地址空间）。

### D2: Post-request cooldown (仅成功发起 HTTP 后生效)

```
search() 出口（unlock 前）:
  if (http_request_was_sent):          // 只有真正发了 curl 请求才计 cooldown
    sleep_remaining = cooldown_ms - elapsed_since_last_request
    if (sleep_remaining > 0):
      sleep_for(sleep_remaining)
    last_request_time = now
```

空 key、空 query、curl_init 失败等 0ms 错误路径**不触发** cooldown——没发 HTTP 请求，无需等。
默认 cooldown 500ms。放在 `unlock` 前。

### D3: Exponential backoff on consecutive 400 errors

```
if (http_code == 400 && body contains "不安全" || "敏感"):
  consecutive_400_count++
  actual_cooldown = base_cooldown * (1 << min(consecutive_400_count, 3))
  // 500ms → 1s → 2s → 4s (max)
else:
  consecutive_400_count = 0
```

连续收到内容审核 400 时指数退避，防止已被封禁状态下继续轰炸。一次正常的 200 或 429 重置计数。

### D4: Exception safety

使用 `std::lock_guard`，异常时自动释放锁。

## Risks

| Risk | Mitigation |
|------|------------|
| 30s 超时阻塞后续请求 | mutex 保护整个 search() 周期。极端情况 3 个并发 ZhipuAI 请求排队 90s。实际场景中超时罕见（API 通常在 1-2s 内返回），且 Kimi 不受影响可并行使用 |
| 死锁 | `std::lock_guard` RAII + 无嵌套锁，不可能死锁 |
| 影响 Kimi/SearXNG | 不改其他 provider，仅影响 ZhipuAI |
