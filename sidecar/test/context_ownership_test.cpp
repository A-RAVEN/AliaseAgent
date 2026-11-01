// [context] —— 第一步内部验收：按上下文归属的状态、写闸门、spill 序号、
// 每上下文模型网关、搜索互斥与浏览器代次。
//
// 每条用例都走 `context_api`（导出函数委托的同一实现）。

#include <catch2/catch_all.hpp>

#include <atomic>
#include <chrono>
#include <fstream>
#include <future>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "browser.h"
#include "context.h"
#include "context_api.h"
#include "crash_handler.h"
#include "logger.h"
#include "mock_server.h"
#include "search_provider.h"
#include "spill.h"
#include "temp_dir.h"
#include "tools.h"

using json = nlohmann::json;

namespace {

std::string fixture(const std::string& name) {
  return std::string(FIXTURE_DIR) + "/" + name;
}

const char* VALID_MSG = R"([{"role":"user","content":"hello"}])";

// ---- 每次请求独立的回调落点（不加 userdata，所以按请求各配一组函数）--------
std::atomic<int> g_a_code{999};
std::atomic<int> g_b_code{999};
std::atomic<bool> g_a_done{false};
std::atomic<bool> g_b_done{false};
std::atomic<bool> g_a_first_chunk_seen{false};
const char* g_a_first_chunk_ptr = nullptr;
// 回调时间线（毫秒，steady_clock）：用来核对「同一上下文串行、不同上下文重叠」。
std::atomic<long long> g_a_first_chunk_ms{0};
std::atomic<long long> g_a_done_ms{0};
std::atomic<long long> g_b_first_chunk_ms{0};
std::atomic<long long> g_b_done_ms{0};

long long now_ms() {
  return std::chrono::duration_cast<std::chrono::milliseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void a_chunk(const char* text) {
  if (!g_a_first_chunk_seen.exchange(true)) {
    g_a_first_chunk_ptr = text;
    g_a_first_chunk_ms.store(now_ms());
  }
}
void a_done(int code, const char*, const char*, int, int) {
  g_a_done_ms.store(now_ms());
  g_a_code.store(code);
  g_a_done.store(true);
}
void b_chunk(const char*) {
  if (g_b_first_chunk_ms.load() == 0) g_b_first_chunk_ms.store(now_ms());
}
void b_done(int code, const char*, const char*, int, int) {
  g_b_done_ms.store(now_ms());
  g_b_code.store(code);
  g_b_done.store(true);
}

void reset_callbacks() {
  g_a_code.store(999);
  g_b_code.store(999);
  g_a_done.store(false);
  g_b_done.store(false);
  g_a_first_chunk_seen.store(false);
  g_a_first_chunk_ptr = nullptr;
  g_a_first_chunk_ms.store(0);
  g_a_done_ms.store(0);
  g_b_first_chunk_ms.store(0);
  g_b_done_ms.store(0);
}

int send_request(context::Context& ctx, MockServer& server, int request_id,
                 OnChunkCallback chunk, OnDoneCallback done) {
  return context_api::send_message(ctx, "sk-test", server.base_url().c_str(),
                                   "claude-sonnet-4-6", "", VALID_MSG, "", "", "",
                                   chunk, nullptr, nullptr, done, request_id);
}

bool wait_flag(std::atomic<bool>& flag, std::chrono::seconds timeout) {
  const auto deadline = std::chrono::steady_clock::now() + timeout;
  while (!flag.load()) {
    if (std::chrono::steady_clock::now() >= deadline) return false;
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return true;
}

std::string json_text(const char* raw) { return std::string(raw ? raw : ""); }

std::string read_bytes(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

}  // namespace

// ============================================================================
// 1.3 工作区搬进上下文、写闸门与进程级 staging 锁
// ============================================================================

TEST_CASE("context: 甲设工作区、乙不设，乙的读文件与缺省 cwd 不落到甲目录", "[context]") {
  context::reset_registry_for_tests();
  auto a = context_api::ensure_context("ws-owner", nullptr);
  auto b = context_api::ensure_context("ws-empty", nullptr);

  TempDir tmp;
  tmp.write("only-in-a.txt", "OWNED-BY-A\n");
  REQUIRE(std::string(context_api::set_workspace(*a, tmp.path().c_str())).empty());

  const std::string b_read = json_text(context_api::read_file(*b, "only-in-a.txt"));
  INFO("b read -> " << b_read);
  REQUIRE(b_read.find("\"ok\":false") != std::string::npos);
  REQUIRE(b_read.find("No workspace set") != std::string::npos);

  // 缺省 cwd：在乙上跑 `Test-Path only-in-a.txt`。若实现错误地用甲的工作区当 cwd，
  // 这个文件就在眼前，会打印 True；正确实现继承测试进程的目录，打印 False。
  const std::string run = json_text(context_api::run_command(
      *b, R"({"command":"if (Test-Path 'only-in-a.txt') { 'FOUND-IN-A' } else { 'NOT-IN-A' }"})"));
  INFO("b run -> " << run);
  REQUIRE(run.find("NOT-IN-A") != std::string::npos);
  REQUIRE(run.find("FOUND-IN-A") == std::string::npos);

  context::reset_registry_for_tests();
}

TEST_CASE("context: 两个上下文并发写同一文件，暂存文件互不删除", "[context]") {
  context::reset_registry_for_tests();
  auto a = context_api::ensure_context("stage-a", nullptr);
  auto b = context_api::ensure_context("stage-b", nullptr);
  TempDir tmp;
  REQUIRE(std::string(context_api::set_workspace(*a, tmp.path().c_str())).empty());
  REQUIRE(std::string(context_api::set_workspace(*b, tmp.path().c_str())).empty());

  const std::string body_a(64 * 1024, 'A');
  const std::string body_b(64 * 1024, 'B');
  const std::string req_a =
      json{{"path", "shared.txt"}, {"content", body_a}}.dump();
  const std::string req_b =
      json{{"path", "shared.txt"}, {"content", body_b}}.dump();

  // 停顿加在 staging 锁的临界区里：带锁时另一方必然等它，去掉锁时另一方会在
  // 停顿期间把这份暂存文件清掉，随后的改名直接失败。
  tools::set_staging_pause_for_tests(30);

  std::atomic<int> failures{0};
  std::atomic<int> done{0};
  auto worker = [&](context::Context& ctx, const std::string& req) {
    for (int i = 0; i < 4; ++i) {
      const std::string out = json_text(context_api::write_file(ctx, req.c_str()));
      if (out.find("\"ok\":true") == std::string::npos) {
        ++failures;
      }
      ++done;
    }
  };
  std::thread ta(worker, std::ref(*a), std::cref(req_a));
  std::thread tb(worker, std::ref(*b), std::cref(req_b));
  ta.join();
  tb.join();

  tools::set_staging_pause_for_tests(0);

  INFO("write failures: " << failures.load());
  REQUIRE(done.load() == 8);
  REQUIRE(failures.load() == 0);

  // 最终内容必须是某一次完整写入，不能是两段拼接。
  const std::string final_text = read_bytes(tmp.path() + "/shared.txt");
  REQUIRE((final_text == body_a || final_text == body_b));
  REQUIRE(final_text.size() == body_a.size());

  context::reset_registry_for_tests();
}

// ============================================================================
// 1.4 文件版本表按上下文隔离，且同一上下文的访问受 state_mutex 串行
// ============================================================================

TEST_CASE("context: 甲读 v1、乙写 v2，甲再编辑得到 stale", "[context]") {
  context::reset_registry_for_tests();
  auto a = context_api::ensure_context("obs-a", nullptr);
  auto b = context_api::ensure_context("obs-b", nullptr);
  TempDir tmp;
  tmp.write("x.txt", "version-one\n");
  REQUIRE(std::string(context_api::set_workspace(*a, tmp.path().c_str())).empty());
  REQUIRE(std::string(context_api::set_workspace(*b, tmp.path().c_str())).empty());

  const std::string read = json_text(context_api::read_file(*a, "x.txt"));
  REQUIRE(read.find("version-one") != std::string::npos);

  const std::string wrote = json_text(context_api::write_file(
      *b, json{{"path", "x.txt"}, {"content", "version-two-much-longer\n"}}.dump().c_str()));
  INFO("b write -> " << wrote);
  REQUIRE(wrote.find("\"ok\":true") != std::string::npos);

  const std::string edit = json_text(context_api::edit_file(
      *a, json{{"path", "x.txt"},
               {"edits", json::array({json{{"old_text", "version-one"},
                                           {"new_text", "version-three"}}})}}
              .dump()
              .c_str()));
  INFO("a edit -> " << edit);
  REQUIRE(edit.find("\"code\":\"stale\"") != std::string::npos);

  // 自己的读仍然有效：甲读完之后没有别人改过，编辑必须成功。
  const std::string read2 = json_text(context_api::read_file(*a, "x.txt"));
  REQUIRE(read2.find("version-two-much-longer") != std::string::npos);
  const std::string edit2 = json_text(context_api::edit_file(
      *a, json{{"path", "x.txt"},
               {"edits", json::array({json{{"old_text", "version-two"},
                                           {"new_text", "version-four"}}})}}
              .dump()
              .c_str()));
  INFO("a edit2 -> " << edit2);
  REQUIRE(edit2.find("\"ok\":true") != std::string::npos);

  context::reset_registry_for_tests();
}

TEST_CASE("context: 版本表访问被 state_mutex 串行（临界区并发数恒为 1）", "[context]") {
  context::reset_registry_for_tests();
  auto ctx = context_api::ensure_context("obs-lock", nullptr);
  ctx->reset_observed_max_concurrent_for_tests();
  // 临界区里停 30ms：没有锁时另一线程必然在这段时间里进入，并发数会到 2。
  ctx->set_observation_pause_for_tests(30);

  std::atomic<int> done{0};
  auto worker = [&]() {
    context::FileVersion v;
    for (int i = 0; i < 3; ++i) {
      ctx->record_observation("p" + std::to_string(i), v);
      ctx->observed_version("p" + std::to_string(i), v);
      ++done;
    }
  };
  std::thread t1(worker);
  std::thread t2(worker);
  t1.join();
  t2.join();

  ctx->set_observation_pause_for_tests(0);
  REQUIRE(done.load() == 6);
  INFO("max concurrent in critical section: " << ctx->observed_max_concurrent_for_tests());
  REQUIRE(ctx->observed_max_concurrent_for_tests() == 1);

  context::reset_registry_for_tests();
}

// ============================================================================
// 1.5 spill 序号按上下文原子取号
// ============================================================================

TEST_CASE("context: 两个线程直接调内部 spill 写入入口，序号不同且文件不互相覆盖", "[context]") {
  context::reset_registry_for_tests();
  auto ctx = context_api::ensure_context("spill-seq", nullptr);
  TempDir root;
  spill::set_root_for_tests(root.path());
  ctx->reset_spill_seq_for_tests();

  const std::string content_a(2048, 'A');
  const std::string content_b(2048, 'B');
  spill::Written wa;
  spill::Written wb;
  std::thread ta([&]() { wa = spill::write_for_context(*ctx, "dir-a", "stdout", content_a); });
  std::thread tb([&]() { wb = spill::write_for_context(*ctx, "dir-b", "stdout", content_b); });
  ta.join();
  tb.join();

  INFO("a: " << wa.path << " b: " << wb.path);
  REQUIRE(wa.ok);
  REQUIRE(wb.ok);
  REQUIRE(wa.path != wb.path);
  // 序号来自同一个原子计数器：两次取号必然不同，且正好是 1 与 2。
  const bool a1 = wa.path.find("000001") != std::string::npos;
  const bool a2 = wa.path.find("000002") != std::string::npos;
  const bool b1 = wb.path.find("000001") != std::string::npos;
  const bool b2 = wb.path.find("000002") != std::string::npos;
  REQUIRE(((a1 && b2) || (a2 && b1)));

  // 内容各自完整，没有被对方覆盖。
  const std::string got_a = read_bytes(wa.path);
  const std::string got_b = read_bytes(wb.path);
  REQUIRE(got_a == content_a);
  REQUIRE(got_b == content_b);

  spill::set_root_for_tests("");
  context::reset_registry_for_tests();
}

TEST_CASE("context: 同一句柄并发 run_command 经业务入口也得到不同 spill 文件", "[context]") {
  context::reset_registry_for_tests();
  auto ctx = context_api::ensure_context("spill-run", nullptr);
  TempDir tmp;
  TempDir root;
  REQUIRE(std::string(context_api::set_workspace(*ctx, tmp.path().c_str())).empty());
  spill::set_root_for_tests(root.path());
  ctx->reset_spill_seq_for_tests();

  std::string out1;
  std::string out2;
  std::thread t1([&]() {
    out1 = json_text(context_api::run_command(
        *ctx, "{\"command\":\"Write-Output 'one-one-one'\"}"));
  });
  std::thread t2([&]() {
    out2 = json_text(context_api::run_command(
        *ctx, "{\"command\":\"Write-Output 'two-two-two'\"}"));
  });
  t1.join();
  t2.join();
  INFO("run1 -> " << out1);
  INFO("run2 -> " << out2);
  REQUIRE(out1.find("\"ok\":true") != std::string::npos);
  REQUIRE(out2.find("\"ok\":true") != std::string::npos);
  REQUIRE(out1.find("one-one-one") != std::string::npos);
  REQUIRE(out2.find("two-two-two") != std::string::npos);

  const auto j1 = json::parse(out1);
  const auto j2 = json::parse(out2);
  const std::string ref1 = j1["spill"]["stdout"]["ref"].get<std::string>();
  const std::string ref2 = j2["spill"]["stdout"]["ref"].get<std::string>();
  INFO("ref1: " << ref1 << " ref2: " << ref2);
  REQUIRE(ref1 != ref2);

  spill::set_root_for_tests("");
  context::reset_registry_for_tests();
}

// ============================================================================
// 1.6 每上下文一份模型网关；取消只打自己；FFI 环形缓冲有生命周期锁
// ============================================================================

TEST_CASE("context: 同一上下文请求串行、不同上下文执行区间重叠", "[context]") {
  // 两个独立的慢速 SSE 服务：如果网关仍是全局一把锁，同一上下文的两个请求会被
  // 串起来；如果不同上下文共用全局锁，两个请求会被串起来而不是重叠。
  MockServer slow_a;
  slow_a.start(fixture("text_delta.txt"));
  slow_a.wait_ready();
  slow_a.set_multi_request(true);
  slow_a.set_streaming_chunks(32, 15);
  MockServer slow_b;
  slow_b.start(fixture("text_delta.txt"));
  slow_b.wait_ready();
  slow_b.set_multi_request(true);
  slow_b.set_streaming_chunks(32, 15);

  context::reset_registry_for_tests();
  auto a = context_api::ensure_context("gw-a", nullptr);
  auto b = context_api::ensure_context("gw-b", nullptr);
  reset_callbacks();

  // 同一上下文：两个请求分别打到两个独立服务上，仍然必须串行。
  std::thread t1([&]() { send_request(*a, slow_a, 11, a_chunk, a_done); });
  std::thread t2([&]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    send_request(*a, slow_b, 12, b_chunk, b_done);
  });
  t1.join();
  t2.join();
  INFO("same context: a [" << g_a_first_chunk_ms.load() << ", " << g_a_done_ms.load()
                           << "] b [" << g_b_first_chunk_ms.load() << ", "
                           << g_b_done_ms.load() << "]");
  REQUIRE(g_a_code.load() == 0);
  REQUIRE(g_b_code.load() == 0);
  // 串行：乙的第一段回调必须落在甲结束之后（留 5ms 容差给回调投递）。
  REQUIRE(g_b_first_chunk_ms.load() >= g_a_done_ms.load() - 5);

  // 不同上下文：两个请求的执行区间必须重叠。
  reset_callbacks();
  std::thread t3([&]() { send_request(*a, slow_a, 13, a_chunk, a_done); });
  std::thread t4([&]() {
    std::this_thread::sleep_for(std::chrono::milliseconds(20));
    send_request(*b, slow_b, 14, b_chunk, b_done);
  });
  t3.join();
  t4.join();
  INFO("different contexts: a [" << g_a_first_chunk_ms.load() << ", " << g_a_done_ms.load()
                                 << "] b [" << g_b_first_chunk_ms.load() << ", "
                                 << g_b_done_ms.load() << "]");
  REQUIRE(g_a_code.load() == 0);
  REQUIRE(g_b_code.load() == 0);
  const bool overlap = g_b_first_chunk_ms.load() < g_a_done_ms.load() &&
                       g_a_first_chunk_ms.load() < g_b_done_ms.load();
  REQUIRE(overlap);

  slow_a.stop();
  slow_a.join();
  slow_b.stop();
  slow_b.join();
  context::reset_registry_for_tests();
}

TEST_CASE("context: 取消甲不影响乙，乙启动不清甲的回调字符串", "[context]") {
  MockServer slow_a;
  slow_a.start(fixture("text_delta.txt"));
  slow_a.wait_ready();
  slow_a.set_multi_request(true);
  slow_a.set_streaming_chunks(24, 20);
  MockServer slow_b;
  slow_b.start(fixture("text_delta.txt"));
  slow_b.wait_ready();
  slow_b.set_multi_request(true);

  context::reset_registry_for_tests();
  auto a = context_api::ensure_context("cancel-a", nullptr);
  auto b = context_api::ensure_context("cancel-b", nullptr);
  reset_callbacks();

  std::thread ta([&]() { send_request(*a, slow_a, 21, a_chunk, a_done); });
  REQUIRE(wait_flag(g_a_first_chunk_seen, std::chrono::seconds(10)));

  // 乙的另一份网关启动并完整跑一次：不得清掉甲仍在等待投递的回调字符串。
  std::thread tb([&]() { send_request(*b, slow_b, 22, b_chunk, b_done); });

  // 取消甲的请求（只针对甲的句柄与 id）。
  context_api::cancel_request(*a, 21);

  ta.join();
  tb.join();
  INFO("a code=" << g_a_code.load() << " b code=" << g_b_code.load()
                 << " a done=" << g_a_done.load() << " b done=" << g_b_done.load());
  REQUIRE(g_a_code.load() == -1);
  REQUIRE(g_b_code.load() == 0);

  // 甲的第一段回调字符串仍可读（乙的网关没有清它）。
  REQUIRE(g_a_first_chunk_ptr != nullptr);
  REQUIRE(std::string(g_a_first_chunk_ptr) == "Hello from Claude!");

  slow_a.stop();
  slow_a.join();
  slow_b.stop();
  slow_b.join();
  context::reset_registry_for_tests();
}

TEST_CASE("context: 销毁最后一个网关后崩溃转储不再解引用已释放内存", "[context]") {
  MockServer server;
  server.start(fixture("text_delta.txt"));
  server.wait_ready();
  server.set_multi_request(true);

  context::reset_registry_for_tests();
  {
    auto a = context_api::ensure_context("ring-a", nullptr);
    auto b = context_api::ensure_context("ring-b", nullptr);
    reset_callbacks();
    send_request(*a, server, 31, a_chunk, a_done);
    send_request(*b, server, 32, b_chunk, b_done);
    REQUIRE(g_a_code.load() == 0);
    REQUIRE(g_b_code.load() == 0);
  }
  // 两个上下文仍被注册表用 shared_ptr 持有：不清注册表的话，网关根本没销毁，
  // 后面的转储证明不了「析构时清空指针」。先显式销毁，再转储。
  context::reset_registry_for_tests();
  // 两个上下文（含各自的网关）现在都已销毁：转储只允许打印 empty，不得读旧指针。
  dump_ffi_ring_buffer();
  // 再跑一次，登记仍然工作（不因为上次清空就再也不登记）。
  {
    auto c = context_api::ensure_context("ring-c", nullptr);
    reset_callbacks();
    send_request(*c, server, 33, a_chunk, a_done);
    REQUIRE(g_a_code.load() == 0);
  }
  // 同上：第二个上下文也要先真正销毁，第二次转储才是在验证清空后的指针。
  context::reset_registry_for_tests();
  dump_ffi_ring_buffer();

  server.stop();
  server.join();
  context::reset_registry_for_tests();
}

// ============================================================================
// 1.7 搜索执行进程级互斥；日志首次初始化线程安全
// ============================================================================

namespace {

class ConcurrencyProbeProvider : public ISearchProvider {
 public:
  std::string name() const override { return "fake"; }
  std::string description() const override { return "test-only provider"; }
  bool is_configured() const override { return true; }
  ProviderResult search(const std::string& query, const std::string&, int) override {
    const int now = active_.fetch_add(1) + 1;
    int seen = max_active_.load();
    while (now > seen && !max_active_.compare_exchange_weak(seen, now)) {
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    active_.fetch_sub(1);
    SearchResult r;
    r.title = "echo:" + query;
    r.url = "https://example.invalid/" + query;
    r.content = "result for " + query;
    return {{r}, {}};
  }
  int max_active() const { return max_active_.load(); }

 private:
  std::atomic<int> active_{0};
  std::atomic<int> max_active_{0};
};

}  // namespace

TEST_CASE("context: 两个上下文并发 web_search 时假 provider 一次只看到一个在跑", "[context]") {
  context::reset_registry_for_tests();
  auto a = context_api::ensure_context("search-a", nullptr);
  auto b = context_api::ensure_context("search-b", nullptr);

  auto probe = std::make_shared<ConcurrencyProbeProvider>();
  set_test_providers({probe});

  std::string out_a;
  std::string out_b;
  std::thread ta([&]() {
    out_a = json_text(context_api::web_search(*a, R"({"query":"alpha","providers":["fake"]})"));
  });
  std::thread tb([&]() {
    out_b = json_text(context_api::web_search(*b, R"({"query":"beta","providers":["fake"]})"));
  });
  ta.join();
  tb.join();

  INFO("a -> " << out_a);
  INFO("b -> " << out_b);
  REQUIRE(out_a.find("\"ok\":true") != std::string::npos);
  REQUIRE(out_b.find("\"ok\":true") != std::string::npos);
  // 两个结果各自完整、没有混进对方的那一条。
  REQUIRE(out_a.find("result for alpha") != std::string::npos);
  REQUIRE(out_a.find("result for beta") == std::string::npos);
  REQUIRE(out_b.find("result for beta") != std::string::npos);
  REQUIRE(out_b.find("result for alpha") == std::string::npos);
  // 进程级互斥：provider 内部同时只观察到一次执行。
  REQUIRE(probe->max_active() == 1);

  set_test_providers({});
  context::reset_registry_for_tests();
}

TEST_CASE("context: 两个线程并发首次初始化日志不崩且都写进同一份日志", "[context]") {
  TempDir dir;
  const std::string log_dir = dir.path() + "/logs";
  std::atomic<int> failures{0};
  auto init_once = [&]() {
    try {
      Logger::instance().init(log_dir);
      LOG_INFO("concurrent-init");
    } catch (...) {
      ++failures;
    }
  };
  std::thread t1(init_once);
  std::thread t2(init_once);
  t1.join();
  t2.join();
  REQUIRE(failures.load() == 0);

  std::ifstream f(log_dir + "/sidecar.log", std::ios::binary);
  REQUIRE(f.good());
  std::string all((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  REQUIRE(all.find("concurrent-init") != std::string::npos);
}

// ============================================================================
// 1.9 浏览器 worker 每进程一份、按代次归属
// ============================================================================

TEST_CASE("context: 浏览器死亡后一个上下文重开，另一个上下文仍收到 dead", "[context][browser-generation]") {
  auto avail = json::parse(context_api::browser_available());
  if (!avail.value("available", false)) {
    WARN("browser stack absent - 跳过真实浏览器代次用例");
    SUCCEED();
    return;
  }
  context::reset_registry_for_tests();
  auto a = context_api::ensure_context("br-a", nullptr);
  auto b = context_api::ensure_context("br-b", nullptr);

  struct Bind {
    explicit Bind(context::Context& c) : ctx(c), previous(context::Context::bind(&c)) {}
    ~Bind() { context::Context::bind(previous); }
    context::Context& ctx;
    context::Context* previous;
  };

  // 甲、乙**同时**首次使用：只应产生一个 worker 代次，两个上下文都拿到它。
  {
    Bind ba(*a);
    browser::reset_session(false);
  }
  {
    Bind bb(*b);
    browser::reset_session(false);
  }
  std::string nav_a;
  std::string nav_b;
  std::thread first_a([&]() {
    nav_a = json_text(context_api::browser_navigate(
        *a, "{\"url\":\"data:text/html,<h1>ALPHA</h1>\"}"));
  });
  std::thread first_b([&]() {
    nav_b = json_text(context_api::browser_navigate(
        *b, "{\"url\":\"data:text/html,<h1>BETA</h1>\"}"));
  });
  first_a.join();
  first_b.join();
  INFO("nav a -> " << nav_a);
  INFO("nav b -> " << nav_b);
  REQUIRE(nav_a.find("ALPHA") != std::string::npos);
  REQUIRE(nav_b.find("BETA") != std::string::npos);
  REQUIRE(a->browser_state().generation == b->browser_state().generation);
  REQUIRE(a->browser_state().generation > 0);

  const std::uint64_t generation_before = a->browser_state().generation;

  // 模拟子进程死亡：甲先收到 dead 并重开（推进代次），乙随后调用仍必须收到 dead。
  {
    Bind ba(*a);
    browser::reset_session(true);
  }
  std::string dead_a;
  {
    Bind ba(*a);
    dead_a = json_text(context_api::browser_navigate(*a, "{\"url\":\"data:text/html,again\"}"));
  }
  INFO("dead a -> " << dead_a);
  REQUIRE(dead_a.find("\"dead\":true") != std::string::npos);
  std::string reopened_a;
  {
    Bind ba(*a);
    reopened_a = json_text(context_api::browser_navigate(
        *a, "{\"url\":\"data:text/html,<h1>REOPENED</h1>\"}"));
  }
  INFO("reopened a -> " << reopened_a);
  REQUIRE(reopened_a.find("REOPENED") != std::string::npos);
  REQUIRE(a->browser_state().generation > generation_before);

  std::string dead_b;
  {
    Bind bb(*b);
    dead_b = json_text(context_api::browser_navigate(*b, "{\"url\":\"data:text/html,later\"}"));
  }
  INFO("dead b -> " << dead_b);
  REQUIRE(dead_b.find("\"dead\":true") != std::string::npos);

  // 销毁时子进程已死：close 只清本地记录，不得为了清理再起一个进程。
  {
    Bind ba(*a);
    browser::reset_session(true);
  }
  {
    Bind ba(*a);
    browser::close_context(*a);
  }
  REQUIRE(a->browser_state().has_session == false);

  context::reset_registry_for_tests();
}
