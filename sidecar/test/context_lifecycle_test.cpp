// [context] —— 第二步公开接口的验收：create/dispose 的 JSON 契约、销毁排空、
// 未知句柄的错误形状、机器级接口不受影响。
//
// change `add-context-handles` 任务 2.1 / 2.2 / 2.3。

#include <catch2/catch_all.hpp>

#include <atomic>
#include <chrono>
#include <functional>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "context.h"
#include "context_api.h"
#include "mock_server.h"
#include "temp_dir.h"

using json = nlohmann::json;

namespace {

std::string fixture(const std::string& name) {
  return std::string(FIXTURE_DIR) + "/" + name;
}

const char* VALID_MSG = R"([{"role":"user","content":"hello"}])";

std::string call(const char* raw) { return std::string(raw ? raw : ""); }

json parse_json(const std::string& text) {
  auto j = json::parse(text);
  return j;
}

bool wait_until(const std::function<bool()>& predicate, std::chrono::seconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (!predicate()) {
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return true;
}

// 慢速模型请求的回调落点
std::atomic<int> g_done_code{999};
std::atomic<bool> g_done_seen{false};
std::atomic<long long> g_done_at{0};
std::atomic<bool> g_first_chunk_seen{false};

long long now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void slow_chunk(const char*) { g_first_chunk_seen.store(true); }
void slow_done(int code, const char*, const char*, int, int) {
  g_done_at.store(now_ms());
  g_done_code.store(code);
  g_done_seen.store(true);
}

void reset_slow_callbacks() {
  g_done_code.store(999);
  g_done_seen.store(false);
  g_done_at.store(0);
  g_first_chunk_seen.store(false);
}

/// 在 worker 线程里发一个慢请求（MockServer 每 24 字节停 20ms）。
int send_slow(const char* handle, MockServer& server, int request_id) {
  return context_api::send_message(handle, "sk-test", server.base_url().c_str(),
                                   "claude-sonnet-4-6", "", VALID_MSG, "", "", "",
                                   slow_chunk, nullptr, nullptr, slow_done, request_id);
}

}  // namespace

// ============================================================================
// 2.1 create_context / dispose_context 的 JSON 契约
// ============================================================================

TEST_CASE("context: 创建接口的 JSON 契约与幂等", "[context]") {
  context::reset_registry_for_tests();

  const json first = parse_json(call(context_api::create_context_json("agent-7")));
  INFO("first -> " << first.dump());
  REQUIRE(first["ok"] == true);
  REQUIRE(first["handle"] == "agent-7");
  REQUIRE(first["created"] == true);

  // 第一次创建后设置工作区；第二次同名创建必须保留它（created:false 不覆盖）。
  TempDir ws;
  REQUIRE(std::string(context_api::set_workspace(
              "agent-7", ws.path().c_str())).empty());

  const json second = parse_json(call(context_api::create_context_json("agent-7")));
  INFO("second -> " << second.dump());
  REQUIRE(second["ok"] == true);
  REQUIRE(second["handle"] == "agent-7");
  REQUIRE(second["created"] == false);
  const json read = parse_json(
      call(context_api::read_file("agent-7", "missing-but-workspace-known.txt")));
  REQUIRE(read["error"] != "No workspace set");

  // 空名字与两个保留名。
  const json empty = parse_json(call(context_api::create_context_json("")));
  REQUIRE(empty["ok"] == false);
  REQUIRE(empty["code"] == "empty_context");
  const json reserved = parse_json(call(context_api::create_context_json("no-session")));
  REQUIRE(reserved["ok"] == false);
  REQUIRE(reserved["code"] == "reserved_context");
  const json reserved_it = parse_json(call(context_api::create_context_json("_it_x")));
  REQUIRE(reserved_it["ok"] == false);
  REQUIRE(reserved_it["code"] == "reserved_context");

  // 销毁后重建：一份空状态（工作区没被带过来）。
  const json disposed = parse_json(call(context_api::dispose_context_json("agent-7")));
  INFO("disposed -> " << disposed.dump());
  REQUIRE(disposed["ok"] == true);
  REQUIRE(disposed["disposed"] == true);
  const json again = parse_json(call(context_api::dispose_context_json("agent-7")));
  REQUIRE(again["ok"] == true);
  REQUIRE(again["disposed"] == false);  // 第二次销毁幂等、无副作用

  const json recreated = parse_json(call(context_api::create_context_json("agent-7")));
  REQUIRE(recreated["ok"] == true);
  REQUIRE(recreated["created"] == true);
  const json read_after = parse_json(
      call(context_api::read_file("agent-7", "still-missing.txt")));
  INFO("read after recreate -> " << read_after.dump());
  REQUIRE(read_after["error"] == "No workspace set");

  context::reset_registry_for_tests();
}

TEST_CASE("context: 两个线程各自创建不同句柄，返回的 JSON 互不覆盖", "[context]") {
  context::reset_registry_for_tests();

  std::string json_a;
  std::string json_b;
  std::thread ta([&]() { json_a = call(context_api::create_context_json("parallel-a")); });
  std::thread tb([&]() { json_b = call(context_api::create_context_json("parallel-b")); });
  ta.join();
  tb.join();

  INFO("a -> " << json_a << " b -> " << json_b);
  REQUIRE(parse_json(json_a)["handle"] == "parallel-a");
  REQUIRE(parse_json(json_b)["handle"] == "parallel-b");
  REQUIRE(json_a.find("parallel-b") == std::string::npos);
  REQUIRE(json_b.find("parallel-a") == std::string::npos);

  context::reset_registry_for_tests();
}

// ============================================================================
// 2.2 销毁排空：先停入口、取消、等在途归零，再释放
// ============================================================================

TEST_CASE("context: 销毁期间同名创建被拒、新调用立即失败、旧调用有真实结束", "[context]") {
  context::reset_registry_for_tests();
  TempDir ws;
  REQUIRE(parse_json(call(context_api::create_context_json("drain-me")))["created"] == true);
  REQUIRE(std::string(context_api::set_workspace("drain-me", ws.path().c_str())).empty());

  // 一个**不会被销毁打断**的旧调用：命令自己睡 1.5 秒。销毁必须等它真的结束，
  // 不能提前释放资源，也不能把命令半路掐掉算成功。
  std::atomic<bool> command_returned{false};
  std::string command_json;
  std::atomic<long long> command_end_ms{0};
  std::thread command_thread([&]() {
    command_json = call(context_api::run_command(
        "drain-me",
        R"({"command":"Start-Sleep -Milliseconds 1500; Write-Output DRAINED-OUTPUT"})"));
    command_end_ms.store(now_ms());
    command_returned.store(true);
  });
  // 等命令真的开始（进程起来 + 进入 PowerShell）。
  std::this_thread::sleep_for(std::chrono::milliseconds(300));

  std::atomic<bool> dispose_returned{false};
  std::string dispose_json;
  std::atomic<long long> dispose_end_ms{0};
  std::thread dispose_thread([&]() {
    dispose_json = call(context_api::dispose_context_json("drain-me"));
    dispose_end_ms.store(now_ms());
    dispose_returned.store(true);
  });

  // 清理完成前，同名创建必须被拒（不许新旧两份同名上下文并存）。
  REQUIRE(wait_until([&]() {
    auto c = context::Registry::instance().find("drain-me");
    return c != nullptr && c->disposing();
  }, std::chrono::seconds(5)));
  const json disposing = parse_json(call(context_api::create_context_json("drain-me")));
  INFO("create during dispose -> " << disposing.dump());
  REQUIRE(disposing["ok"] == false);
  REQUIRE(disposing["code"] == "context_disposing");

  // 新调用立即失败（销毁中的上下文等同未知句柄）。
  const json rejected = parse_json(call(context_api::read_file("drain-me", "x.txt")));
  INFO("call during dispose -> " << rejected.dump());
  REQUIRE(rejected["ok"] == false);
  REQUIRE(rejected["code"] == "unknown_context");

  // 旧调用还没结束，销毁不得提前完成。
  REQUIRE(command_returned.load() == false);
  REQUIRE(dispose_returned.load() == false);

  command_thread.join();
  dispose_thread.join();
  INFO("command -> " << command_json);
  INFO("dispose -> " << dispose_json);
  // 旧调用按自身协议真实结束：命令跑完了，输出完整。
  REQUIRE(command_returned.load() == true);
  REQUIRE(parse_json(command_json)["ok"] == true);
  REQUIRE(command_json.find("DRAINED-OUTPUT") != std::string::npos);
  // 资源只在最后一个在途调用结束后释放：销毁返回不早于命令结束。
  REQUIRE(dispose_returned.load() == true);
  REQUIRE(parse_json(dispose_json)["ok"] == true);
  REQUIRE(dispose_end_ms.load() >= command_end_ms.load());
  // 上下文目录与注册表都清掉了。
  REQUIRE(context::Registry::instance().find("drain-me") == nullptr);

  context::reset_registry_for_tests();
}

TEST_CASE("context: 销毁会取消该上下文的模型请求并等它真实结束", "[context]") {
  MockServer server;
  server.start(fixture("text_delta.txt"));
  server.wait_ready();
  server.set_multi_request(true);
  server.set_streaming_chunks(24, 25);
  reset_slow_callbacks();

  context::reset_registry_for_tests();
  REQUIRE(parse_json(call(context_api::create_context_json("drain-model")))["created"] == true);

  std::thread request_thread([&]() { send_slow("drain-model", server, 43); });
  REQUIRE(wait_until([&]() { return g_first_chunk_seen.load(); }, std::chrono::seconds(10)));

  const json disposed = parse_json(call(context_api::dispose_context_json("drain-model")));
  INFO("dispose -> " << disposed.dump());
  REQUIRE(disposed["ok"] == true);
  REQUIRE(disposed["disposed"] == true);

  request_thread.join();
  // 旧的模型请求有真实结束记录：被取消（-1），不是凭空冒出来的成功。
  REQUIRE(g_done_seen.load() == true);
  REQUIRE(g_done_code.load() == -1);
  REQUIRE(context::Registry::instance().find("drain-model") == nullptr);

  server.stop();
  server.join();
  context::reset_registry_for_tests();
}

TEST_CASE("context: 毒化且仍有在途调用时销毁如实失败并保留资源", "[context]") {
  MockServer server;
  server.start(fixture("text_delta.txt"));
  server.wait_ready();
  server.set_multi_request(true);
  server.set_streaming_chunks(24, 30);
  reset_slow_callbacks();

  context::reset_registry_for_tests();
  REQUIRE(parse_json(call(context_api::create_context_json("poisoned-ctx")))["created"] == true);

  std::thread request_thread([&]() { send_slow("poisoned-ctx", server, 42); });
  REQUIRE(wait_until([&]() { return g_first_chunk_seen.load(); }, std::chrono::seconds(10)));

  // 模拟 Dart 桥的兜底判决：取消失败 ⇒ 该上下文被标为毒化。
  auto ctx = context::Registry::instance().find("poisoned-ctx");
  REQUIRE(ctx != nullptr);
  ctx->mark_poisoned();

  const json failed = parse_json(call(context_api::dispose_context_json("poisoned-ctx")));
  INFO("dispose poisoned -> " << failed.dump());
  REQUIRE(failed["ok"] == false);
  REQUIRE(failed["code"] == "dispose_not_drained");
  // 资源保留：上下文仍在注册表里，同名重建仍被拒。
  REQUIRE(context::Registry::instance().find("poisoned-ctx") != nullptr);
  const json rebuild = parse_json(call(context_api::create_context_json("poisoned-ctx")));
  REQUIRE(rebuild["ok"] == false);
  REQUIRE(rebuild["code"] == "context_disposing");

  // 收尾：取消真实请求，等它结束，再清注册表。
  context_api::cancel_request("poisoned-ctx", 42);
  request_thread.join();
  REQUIRE(g_done_seen.load() == true);

  server.stop();
  server.join();
  context::reset_registry_for_tests();
}

// ============================================================================
// 2.3 未知句柄的错误形状；机器级接口不受影响
// ============================================================================

TEST_CASE("context: 机器级接口在没有上下文时也能调用", "[context]") {
  context::reset_registry_for_tests();
  REQUIRE(context::Registry::instance().size() == 0);

  const std::string infra = call(context_api::ensure_search_infra("{}"));
  INFO("ensure_search_infra -> " << infra);
  REQUIRE(parse_json(infra)["ok"] == true);

  const std::string providers = call(context_api::get_search_providers());
  REQUIRE(providers.front() == '[');  // JSON 数组，不是 unknown_context

  const json available = parse_json(call(context_api::browser_available()));
  INFO("browser_available -> " << available.dump());
  REQUIRE(available.contains("available"));
  REQUIRE(available.dump().find("unknown_context") == std::string::npos);
}

TEST_CASE("context: 未知句柄在每种接口上的错误形状", "[context]") {
  context::reset_registry_for_tests();
  const char* missing = "never-created";

  struct JsonOp {
    const char* name;
    const char* (*fn)(const char*, const char*);
  };
  const JsonOp ops[] = {
      {"read_file", context_api::read_file},
      {"list_dir", context_api::list_dir},
      {"write_file", context_api::write_file},
      {"edit_file", context_api::edit_file},
      {"glob_file", context_api::glob_file},
      {"grep_file", context_api::grep_file},
      {"read_image", context_api::read_image},
      {"read_clipboard_image", context_api::read_clipboard_image},
      {"run_command", context_api::run_command},
      {"read_spill", context_api::read_spill},
      {"browser_navigate", context_api::browser_navigate},
      {"browser_click", context_api::browser_click},
      {"browser_type", context_api::browser_type},
      {"browser_snapshot", context_api::browser_snapshot},
      {"web_search", context_api::web_search},
      {"web_fetch", context_api::web_fetch},
  };
  for (const auto& op : ops) {
    const json j = parse_json(call(op.fn(missing, "{}")));
    INFO(op.name << " -> " << j.dump());
    REQUIRE(j["ok"] == false);
    REQUIRE(j["code"] == "unknown_context");
  }

  // set_workspace：纯文本，不伪装成成功空串。
  const std::string ws = call(context_api::set_workspace(missing, "."));
  INFO("set_workspace -> " << ws);
  REQUIRE(ws == "unknown_context: never-created");

  // cancel_request：JSON 错误，不静默忽略。
  const json cancel = parse_json(call(context_api::cancel_request(missing, 7)));
  REQUIRE(cancel["ok"] == false);
  REQUIRE(cancel["code"] == "unknown_context");

  // send_message：返回负数并经 on_done 报错，不发起 HTTP。
  reset_slow_callbacks();
  const int rc = context_api::send_message(missing, "sk-test", "http://127.0.0.1:1",
                                           "m", "", VALID_MSG, "", "", "", slow_chunk,
                                           nullptr, nullptr, slow_done, 99);
  INFO("send_message rc=" << rc);
  REQUIRE(rc < 0);
  REQUIRE(g_done_seen.load() == true);
  REQUIRE(g_done_code.load() == -2);

  // 隐式创建没发生：再创建同名上下文是全新的一份。
  const json fresh = parse_json(call(context_api::create_context_json(missing)));
  REQUIRE(fresh["created"] == true);

  context::reset_registry_for_tests();
}

TEST_CASE("context: get_workspace 对未知与已销毁句柄返回 unknown_context，空工作区如实为空",
          "[context][get_workspace]") {
  context::reset_registry_for_tests();

  // 未知句柄：JSON 错误，不隐式创建；失败的时候也不能伪造出一个工作区。
  const json missing = parse_json(call(context_api::get_workspace("never-created-ws")));
  INFO("missing -> " << missing.dump());
  REQUIRE(missing["ok"] == false);
  REQUIRE(missing["code"] == "unknown_context");
  REQUIRE(context::Registry::instance().find("never-created-ws") == nullptr);

  // 新建但未设工作区：如实返回空串，不替换成应用主目录或别的上下文的工作区。
  REQUIRE(parse_json(call(context_api::create_context_json("ws-empty")))["created"] == true);
  const json empty = parse_json(call(context_api::get_workspace("ws-empty")));
  INFO("empty -> " << empty.dump());
  REQUIRE(empty["ok"] == true);
  REQUIRE(empty["workspace"] == "");

  // 设置后再读：返回的必须就是这一份工作区（规范化后的实际保存值）。
  TempDir ws;
  REQUIRE(std::string(context_api::set_workspace("ws-empty", ws.path().c_str())).empty());
  const json before = parse_json(call(context_api::get_workspace("ws-empty")));
  INFO("before dispose -> " << before.dump());
  REQUIRE(before["ok"] == true);
  REQUIRE(before["workspace"].get<std::string>().find("st_") != std::string::npos);

  // 销毁后：按未知句柄报错，且查询本身没有把同名上下文隐式建回来。
  REQUIRE(parse_json(call(context_api::dispose_context_json("ws-empty")))["disposed"] == true);
  const json disposed = parse_json(call(context_api::get_workspace("ws-empty")));
  INFO("disposed -> " << disposed.dump());
  REQUIRE(disposed["ok"] == false);
  REQUIRE(disposed["code"] == "unknown_context");
  REQUIRE(context::Registry::instance().find("ws-empty") == nullptr);
  // 同名重建得到的是全新上下文（工作区为空），证明查询没有留下残影。
  REQUIRE(parse_json(call(context_api::create_context_json("ws-empty")))["created"] == true);
  const json reborn = parse_json(call(context_api::get_workspace("ws-empty")));
  INFO("reborn -> " << reborn.dump());
  REQUIRE(reborn["workspace"] == "");

  context::reset_registry_for_tests();
}

TEST_CASE("context: 空 api_key 仍走既有早退（返回 1 且 on_done(0)）", "[context]") {
  context::reset_registry_for_tests();
  REQUIRE(parse_json(call(context_api::create_context_json("empty-key")))["created"] == true);
  reset_slow_callbacks();
  const int rc = context_api::send_message("empty-key", "", "http://127.0.0.1:1", "m", "",
                                           VALID_MSG, "", "", "", slow_chunk, nullptr,
                                           nullptr, slow_done, 100);
  INFO("rc=" << rc << " done=" << g_done_seen.load() << " code=" << g_done_code.load());
  REQUIRE(rc == 1);
  REQUIRE(g_done_seen.load() == true);
  REQUIRE(g_done_code.load() == 0);
  context::reset_registry_for_tests();
}
