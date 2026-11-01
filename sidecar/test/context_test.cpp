// [context] —— 上下文注册表、在途租约与线程本地返回缓冲的内部验收。
//
// 这些用例走 `context_api`：产品导出函数委托给同一批实现，所以这里测到的就是
// 真实路径（不是另测一份临时字符串）。change `add-context-handles` 任务 1.1 / 1.2。

#include <catch2/catch_test_macros.hpp>

#include <filesystem>
#include <fstream>
#include <future>
#include <string>
#include <thread>
#include <vector>

#include "context.h"
#include "context_api.h"
#include "result_buffer.h"
#include "temp_dir.h"

namespace {

std::string read_text(const std::filesystem::path& p) {
  std::ifstream f(p, std::ios::binary);
  return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

}  // namespace

TEST_CASE("context: 并发取同一名字得到同一对象，不同名字不同对象", "[context]") {
  context::reset_registry_for_tests();

  auto first = context_api::ensure_context("same-name", nullptr);
  REQUIRE(first != nullptr);

  std::vector<context::Context*> seen_a(64, nullptr);
  std::vector<context::Context*> seen_b(64, nullptr);
  std::thread ta([&]() {
    for (int i = 0; i < 64; ++i) {
      bool created = true;
      auto p = context_api::ensure_context("same-name", &created);
      seen_a[static_cast<size_t>(i)] = p.get();
      REQUIRE_FALSE(created);
    }
  });
  std::thread tb([&]() {
    for (int i = 0; i < 64; ++i) {
      auto p = context_api::ensure_context("another-name", nullptr);
      seen_b[static_cast<size_t>(i)] = p.get();
    }
  });
  ta.join();
  tb.join();

  for (auto* p : seen_a) REQUIRE(p == first.get());
  for (auto* p : seen_b) {
    REQUIRE(p != nullptr);
    REQUIRE(p != first.get());
  }
  REQUIRE(context::Registry::instance().size() == 2);

  context::reset_registry_for_tests();
  REQUIRE(context::Registry::instance().size() == 0);
}

TEST_CASE("context: result_buffer 的槽按调用线程各存一份", "[context]") {
  result_buffer::Slot& slot = result_buffer::slot_for_tests(0);

  std::promise<void> a_wrote;
  std::promise<void> b_wrote;
  std::string a_value;
  std::string b_value;

  std::thread ta([&]() {
    slot.set("A-value");
    a_wrote.set_value();
    b_wrote.get_future().wait();
    a_value = slot.get();
  });
  std::thread tb([&]() {
    a_wrote.get_future().wait();
    slot.set("B-value");
    b_value = slot.get();
    b_wrote.set_value();
  });
  ta.join();
  tb.join();

  REQUIRE(a_value == "A-value");
  REQUIRE(b_value == "B-value");
}

TEST_CASE("context: 另一线程完成调用后，先拿到的返回内容仍是自己的", "[context]") {
  TempDir tmp;
  tmp.write("a.txt", "AAA-content\n");
  tmp.write("b.txt", "BBB-content\n");

  context::reset_registry_for_tests();
  auto ctx = context_api::ensure_context("buf-same-context", nullptr);
  REQUIRE(context_api::set_workspace(*ctx, tmp.path().c_str())[0] == '\0');

  std::promise<void> a_has_pointer;
  std::promise<void> b_finished;
  std::string a_copy;
  std::string b_copy;

  std::thread ta([&]() {
    const char* p = context_api::read_file(*ctx, "a.txt");
    a_has_pointer.set_value();
    b_finished.get_future().wait();
    // A 在 B 完成之后才复制 —— 指针必须仍指向 A 自己的内容。
    a_copy.assign(p);
  });
  std::thread tb([&]() {
    a_has_pointer.get_future().wait();
    const char* p = context_api::read_file(*ctx, "b.txt");
    b_copy.assign(p);
    b_finished.set_value();
  });
  ta.join();
  tb.join();

  REQUIRE(a_copy.find("AAA-content") != std::string::npos);
  REQUIRE(a_copy.find("BBB-content") == std::string::npos);
  REQUIRE(b_copy.find("BBB-content") != std::string::npos);

  // 不同导出函数各有自己的槽：A 持有 read_file 的指针时，list_dir 完成不得覆盖它。
  std::promise<void> read_has_pointer;
  std::promise<void> list_finished;
  std::string read_copy;
  std::thread t1([&]() {
    const char* p = context_api::read_file(*ctx, "a.txt");
    read_has_pointer.set_value();
    list_finished.get_future().wait();
    read_copy.assign(p);
  });
  std::thread t2([&]() {
    read_has_pointer.get_future().wait();
    const char* p = context_api::list_dir(*ctx, ".");
    REQUIRE(std::string(p).find("a.txt") != std::string::npos);
    list_finished.set_value();
  });
  t1.join();
  t2.join();
  REQUIRE(read_copy.find("AAA-content") != std::string::npos);

  context::reset_registry_for_tests();
}

TEST_CASE("context: 异常分支写回同一个线程本地槽，不再有共享 err_static", "[context]") {
  context::reset_registry_for_tests();
  auto ctx = context_api::ensure_context("buf-exception", nullptr);

  // `command` 传数字会让 nlohmann 的 value() 抛 type_error —— 走 context_api 的
  // 异常分支。错误必须写进同一份线程本地槽，而不是某个共享的静态字符串。
  const char* raw = context_api::run_command(*ctx, "{\"command\":123}");
  std::string err(raw);
  REQUIRE(err.find("\"ok\":false") != std::string::npos);
  REQUIRE(err.find("type must be string") != std::string::npos);

  // 异常分支写的是本函数自己的槽：别处的成功结果不受牵连。
  const char* ok_raw = context_api::get_search_providers();
  REQUIRE(std::string(ok_raw).find("type must be string") == std::string::npos);

  context::reset_registry_for_tests();
}

TEST_CASE("context: sidecar_api.cpp 里已经没有共享的错误缓冲", "[context]") {
  const std::filesystem::path src(SIDECAR_SRC_DIR);
  REQUIRE(std::filesystem::exists(src));
  for (const auto& entry : std::filesystem::directory_iterator(src)) {
    if (!entry.is_regular_file()) continue;
    const auto ext = entry.path().extension().string();
    if (ext != ".cpp" && ext != ".h") continue;
    const std::string text = read_text(entry.path());
    INFO("file: " << entry.path().filename().string());
    // 找声明语句本身，而不是注释里提到这个词（注释说明"不再有它"是应该的）。
    REQUIRE(text.find("static std::string err_static") == std::string::npos);
    REQUIRE(text.find("std::string err_static;") == std::string::npos);
  }
}
