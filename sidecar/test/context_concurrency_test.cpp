// [context-concurrency] —— change `parallelize-readonly-tool-calls` 任务 2.2：
// 同一上下文被多个线程并发调用时的压力用例。
//
// Dart 侧把只读段改并发之后，同一个 sidecar 上下文会被多个 worker isolate 同时
// 调用（每个 isolate 一条 C++ 线程）。既有用例只覆盖到「2 个线程 / 2 个上下文」，
// 这里补上新的调用形态：
//   ① 同一上下文 8 线程并发经业务入口 read_file —— thread_local 返回槽不串；
//   ② 同一上下文 8 线程并发写 spill —— 文件名序号两两不同；
//   ③ 多线程同时首次进入 Python 探测入口 —— 所有线程得到一致结果（覆盖 design D9
//      的 call_once 修复；用一份全新的 PythonProbeState，保证确实是"首次进入"）。

#include <catch2/catch_all.hpp>

#include <atomic>
#include <fstream>
#include <set>
#include <string>
#include <thread>
#include <vector>

#include <nlohmann/json.hpp>

#include "context.h"
#include "context_api.h"
#include "spill.h"
#include "temp_dir.h"
#include "web_fetch.h"

using nlohmann::json;

namespace {

constexpr int kThreads = 8;

/// 让所有线程尽量同时起跑：每个线程报到后自旋，等最后一个报到。
class StartGate {
 public:
    void arrive_and_wait() {
        arrived_.fetch_add(1);
        while (arrived_.load() < kThreads) std::this_thread::yield();
    }

 private:
    std::atomic<int> arrived_{0};
};

std::string read_bytes(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    return std::string((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

}  // namespace

// ---------------------------------------------------------------------------
// ① 并发 read_file：每个线程拿回自己请求的那份内容
// ---------------------------------------------------------------------------

TEST_CASE("context-concurrency: 同一上下文 8 线程并发 read_file 各自拿回自己的内容",
          "[context-concurrency]") {
    context::reset_registry_for_tests();
    auto ctx = context_api::ensure_context("conc-read", nullptr);
    REQUIRE(ctx != nullptr);
    TempDir tmp;
    REQUIRE(std::string(context_api::set_workspace(*ctx, tmp.path().c_str())).empty());

    for (int i = 0; i < kThreads; ++i) {
        tmp.write("file-" + std::to_string(i) + ".txt",
                  "CONTENT-" + std::to_string(i) + "-BEGIN\nline2-" + std::to_string(i) + "\n");
    }

    StartGate gate;
    std::vector<std::string> results(kThreads);
    std::vector<std::thread> threads;
    threads.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        threads.emplace_back([&, i]() {
            gate.arrive_and_wait();
            // 返回值指向本线程的 thread_local 槽，必须在同一线程里立刻拷走。
            results[i] = std::string(context_api::read_file(
                *ctx, ("file-" + std::to_string(i) + ".txt").c_str()));
        });
    }
    for (auto& t : threads) t.join();

    for (int i = 0; i < kThreads; ++i) {
        INFO("线程 " << i << " 读到：" << results[i]);
        REQUIRE(results[i].find("\"ok\":true") != std::string::npos);
        REQUIRE(results[i].find("CONTENT-" + std::to_string(i) + "-BEGIN") !=
                std::string::npos);
        REQUIRE(results[i].find("line2-" + std::to_string(i)) != std::string::npos);
        for (int j = 0; j < kThreads; ++j) {
            if (j == i) continue;
            INFO("线程 " << i << " 的结果里混进了线程 " << j << " 的内容");
            REQUIRE(results[i].find("CONTENT-" + std::to_string(j) + "-BEGIN") ==
                    std::string::npos);
            REQUIRE(results[i].find("line2-" + std::to_string(j)) == std::string::npos);
        }
    }

    context_api::set_workspace(*ctx, "");
    context::reset_registry_for_tests();
}

// ---------------------------------------------------------------------------
// ② 并发写 spill：同一上下文的原子计数器给出两两不同的序号
// ---------------------------------------------------------------------------

TEST_CASE("context-concurrency: 同一上下文 8 线程并发写 spill 文件名序号两两不同",
          "[context-concurrency]") {
    context::reset_registry_for_tests();
    auto ctx = context_api::ensure_context("conc-spill", nullptr);
    REQUIRE(ctx != nullptr);
    TempDir root;
    spill::set_root_for_tests(root.path());
    ctx->reset_spill_seq_for_tests();

    StartGate gate;
    std::vector<spill::Written> written(kThreads);
    std::vector<std::thread> threads;
    threads.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        threads.emplace_back([&, i]() {
            gate.arrive_and_wait();
            written[i] = spill::write_for_context(
                *ctx, "conc", "stdout", std::string(2048, static_cast<char>('A' + i)));
        });
    }
    for (auto& t : threads) t.join();

    std::set<std::string> seqs;
    for (int i = 0; i < kThreads; ++i) {
        INFO("线程 " << i << " 落盘结果：ok=" << written[i].ok << " path=" << written[i].path
                     << " error=" << written[i].error);
        REQUIRE(written[i].ok);
        // 文件名形如 `NNNNNN-stdout.txt`：前 6 位就是序号。
        const size_t slash = written[i].path.find_last_of("/\\");
        const std::string base =
            slash == std::string::npos ? written[i].path : written[i].path.substr(slash + 1);
        REQUIRE(base.size() > 6);
        REQUIRE(base.substr(6) == "-stdout.txt");
        seqs.insert(base.substr(0, 6));
        // 内容各自完整，没有被别的线程覆盖。
        REQUIRE(read_bytes(written[i].path) ==
                std::string(2048, static_cast<char>('A' + i)));
    }
    INFO("取到的 8 个序号：" << [&]() {
        std::string joined;
        for (const auto& s : seqs) joined += s + " ";
        return joined;
    }());
    REQUIRE(seqs.size() == static_cast<size_t>(kThreads));

    spill::set_root_for_tests("");
    context::reset_registry_for_tests();
}

// ---------------------------------------------------------------------------
// ③ 多线程同时首次进入 Python 探测入口：结果必须一致（design D9）
//
// 用一份**全新**的 PythonProbeState 调探测入口，所以本用例就是这份状态的"首次
// 探测"：8 个线程同时进来时，探测体只允许执行一次，结果对所有线程一致可见。
// 还原成无锁实现（`if (checked) return; checked = true; …; available = true;`）时，
// 后到的线程会读到"已置 checked、未置 available"的中间态，于是同时出现 true 与
// false —— 本用例变红。（本机 PATH 上有 Python 3.10.0，探测会走"找到"分支，
// 中间态可观测；实测见任务日志。）
// ---------------------------------------------------------------------------

TEST_CASE("context-concurrency: 多线程同时首次进入 Python 探测入口结果一致",
          "[context-concurrency]") {
    PythonProbeState state;  // 全新状态 = 本用例负责"首次探测"
    StartGate gate;
    // 每个线程写自己那一格：用 int 而不是 vector<bool> —— vector<bool> 是位压缩
    // 特化，8 个下标落在同一个机器字里，多线程各写一格本身就是数据竞争。
    std::vector<int> results(kThreads, 0);
    std::vector<std::thread> threads;
    threads.reserve(kThreads);
    for (int i = 0; i < kThreads; ++i) {
        threads.emplace_back([&, i]() {
            gate.arrive_and_wait();
            results[i] = web_fetch_run_python_probe(state) ? 1 : 0;
        });
    }
    for (auto& t : threads) t.join();

    const bool settled = state.available.load(std::memory_order_acquire);
    for (int i = 0; i < kThreads; ++i) {
        INFO("线程 " << i << " 的探测结果：" << (results[i] != 0)
                     << "（已发布的结果：" << settled << "）");
        REQUIRE(results[i] == (settled ? 1 : 0));
    }
    // 再调一次拿到的还是同一个结果（缓存生效、结果不再变化）。
    REQUIRE(web_fetch_run_python_probe(state) == settled);
}
