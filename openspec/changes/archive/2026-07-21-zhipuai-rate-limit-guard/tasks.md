## 1. C++ Implementation

- [x] 1.1 Add `#include <mutex>` and `#include <thread>` to `zhipuai_search.cpp`
- [x] 1.2 Add static `std::mutex g_zhipuai_mutex`, `static std::chrono::steady_clock::time_point g_last_request_time`, and `static int g_consecutive_400_count` in global scope
- [x] 1.3 At `search()` entry: acquire `std::lock_guard<std::mutex>` (RAII, exception-safe)
- [x] 1.4 After successful HTTP request (curl_easy_perform completed): compute elapsed since `g_last_request_time`, if < base_cooldown (500ms), `std::this_thread::sleep_for()` the remainder. Update `g_last_request_time`.
- [x] 1.5 Skip cooldown when no HTTP request was sent: empty key, empty query, curl_easy_init failure — no curl_easy_perform → no cooldown delay
- [x] 1.6 On HTTP 400 with "不安全" or "敏感" in response body: increment `g_consecutive_400_count`, multiply cooldown by `2^count` (max 4s). Reset count to 0 on any other HTTP status (200, 429, 500, etc.)

## 2. Tests

- [x] 2.1 Unit test: two concurrent `search()` calls via `std::async` — verify both complete with valid results, execution order correct (no wall-clock assertion)
- [x] 2.2 Unit test: sequential calls via mock — verify second call returns after first (no timing assertion, just order-preserving)
- [x] 2.3 Unit test: first call with no prior request — verify no cooldown delay applied (result returns without blocking)
- [x] 2.4 Unit test: 0ms error path (empty key) — verify mutex is released immediately, no cooldown sleep
- [x] 2.5 Unit test: consecutive 400 errors trigger exponential backoff — verify cooldown increases after each 400
- [x] 2.6 Unit test: 400 count resets on successful 200 — verify backoff count back to 0
- [x] 2.7 Verify existing ZhipuAI mock tests still pass (mutex + cooldown doesn't break serial execution)

## 3. Integration

- [x] 3.1 Rebuild sidecar.dll, run full test suite (126/127, 1 pre-existing failure)
- [x] 3.2 Smoke test: `flutter test test/unit/sidecar_bridge_test.dart`
- [x] 3.3 Live test: verify ZhipuAI live test still passes with mutex + cooldown + backoff
- [x] 3.4 Live test: rapid-fire 5 consecutive ZhipuAI searches — 5/5 success, 0 errors, 8370ms total ✓
