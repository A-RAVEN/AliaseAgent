## Why

AI 在同轮对话中可能发出多个带 `providers:["zhipuai"]` 的 `web_search` tool call，`_executeTool` 串行执行但无间隔。正常请求 1-2 秒（有自然间隔），一旦遇到 429（200ms 返回），间隔坍缩为 2ms，0.6 秒内连发 3 个请求。ZhipuAI 将此识别为滥用，从 429 升级到 400 内容审核拦截，导致后续所有请求被拒。

## What Changes

- `ZhipuAISearch::search()` 内部加 static mutex + cooldown（500ms），同一 provider 在任何时刻只允许一个请求在执行，完成后等 500ms 才能发下一个
- 不影响 Kimi、SearXNG 等其他 provider

## Capabilities

### New Capabilities
- `zhipuai-rate-guard`: ZhipuAI provider 内置请求串行化 + cooldown 保护

### Modified Capabilities
- `zhipuai-web-search-api`: `ZhipuAISearch::search()` 增加 mutex + cooldown，修改外部可观测行为（请求时序）

## Impact

- `sidecar/src/zhipuai_search.cpp` — 加 static `std::mutex` + `std::chrono::steady_clock` cooldown
- `sidecar/src/zhipuai_search.h` — 无变更（内部实现细节）
