#ifndef CONTEXT_H
#define CONTEXT_H

// 上下文（change `add-context-handles`）。
//
// 一份上下文持有原本是进程级单例的那批**执行状态**：工作区根、文件版本表、
// spill 调用序号、模型网关、浏览器会话归属。注册表只存 shared_ptr；每次调用
// 先取一个共享引用并增加在途计数，销毁线程因此在调用结束前不会拿到裸引用。
//
// 状态归属见 design 决策 3 / 4：
//   - 每上下文一份：workspace、observed、spill 序号、ModelGateway、浏览器状态；
//   - 每调用线程一份：导出函数的返回字符串（见 result_buffer.h）；
//   - 进程级共享：注册表、暂存文件锁与计数器、搜索设施、浏览器子进程。

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>

class ModelGateway;

namespace context {

/// 一份文件在某一刻的版本（最后写时间 + 大小）。同一次元数据读取，不占句柄。
struct FileVersion {
  long long mtime_ticks = 0;  // Windows: FILETIME 100ns ticks；POSIX: ns since epoch
  long long size = 0;
};

/// 该上下文在浏览器子进程里的会话归属。
struct BrowserSessionState {
  bool has_session = false;   // 该上下文在本代次里是否已经建过 BrowserContext
  bool allow_reopen = false;  // 收到过一次 dead:true 之后，下一次显式重开才被允许
  std::uint64_t generation = 0;  // 会话所属的 worker 代次
};

class Context {
 public:
  explicit Context(std::string name);
  ~Context();

  Context(const Context&) = delete;
  Context& operator=(const Context&) = delete;

  const std::string& name() const { return name_; }

  // ---- 工作区（state_mutex 保护；按值返回，不把锁内引用带出临界区）--------
  std::string workspace() const;
  void set_workspace_value(std::string value);

  // ---- 文件版本表（state_mutex 保护）--------------------------------------
  bool observed_version(const std::string& path, FileVersion& out) const;
  void record_observation(const std::string& path, const FileVersion& version);
  void reset_observations();

  /// 测试用：在版本表临界区里停这么多毫秒（验证锁确实把并发访问串起来）。
  void set_observation_pause_for_tests(int milliseconds);
  /// 测试用：临界区内同时出现过的最大调用数。锁生效时恒为 1；
  /// 去掉锁并制造交错时会读到 2。
  int observed_max_concurrent_for_tests() const;
  void reset_observed_max_concurrent_for_tests();

  // ---- spill 调用序号（每上下文一个原子；不走 state_mutex）---------------
  unsigned next_spill_seq();
  void reset_spill_seq_for_tests();
  /// 把序号下限抬到 `max_seq`（含）：创建上下文时扫描目录续号用。
  void raise_spill_seq_floor(unsigned max_seq);
  unsigned peek_spill_seq() const;

  // ---- 模型网关（每上下文一个，首次使用时创建）----------------------------
  ModelGateway& gateway();

  // ---- 在途计数与生命周期 -------------------------------------------------
  void enter();
  void leave();
  int in_flight() const;
  void mark_disposing();
  /// 尝试标为销毁中：只有第一个调用者拿到 true（销毁不能由两个线程同时做）。
  bool try_mark_disposing();
  bool disposing() const;
  /// 等到在途调用归零（不含调用者自己）。
  void wait_for_idle();
  /// 若已有网关，取消它当前的模型请求；不为了取消而新建网关。
  void cancel_model_if_any();
  void mark_poisoned();
  bool poisoned() const;
  /// 毒化且无法排空时，销毁放弃并保留资源：记下这次失败，后续 dispose 直接报错。
  void mark_dispose_failed();
  bool dispose_failed() const;

  // ---- 写操作闸门（set_workspace / write_file / edit_file / run_command）---
  std::mutex& write_gate() { return write_gate_; }

  // ---- 浏览器会话归属 ------------------------------------------------------
  BrowserSessionState browser_state() const;
  void set_browser_session(bool has_session, std::uint64_t generation);
  void clear_browser_session();
  void set_allow_reopen(bool allow);
  bool allow_reopen() const;

  // ---- 线程本地的「当前上下文」 -------------------------------------------
  /// 本线程显式绑定的上下文；没有绑定时返回 nullptr。
  static Context* bound();
  /// 绑定/解绑当前线程（传 nullptr 解绑）。返回此前绑定的指针，供 RAII 恢复。
  static Context* bind(Context* value);
  /// 当前上下文：显式绑定优先，否则退回进程内隐式上下文。
  static Context& current();
  /// 进程内隐式上下文：只服务那些还没有显式上下文的旧内部调用（见 context_api）。
  static Context& implicit();

 private:
  std::string name_;
  mutable std::mutex state_mutex_;
  std::string workspace_;
  std::map<std::string, FileVersion> observed_;
  // 测试用的并发观察：进入临界区 +1、离开 -1，并记录同时出现的最大值。
  // 锁生效时它只能是 1；这是「去掉 state_mutex 后能被检出」的那条判据。
  mutable std::atomic<int> observed_active_{0};
  mutable std::atomic<int> observed_max_active_{0};
  std::atomic<int> observation_pause_ms_{0};
  std::atomic<unsigned> spill_seq_{0};
  mutable std::mutex gateway_mutex_;
  std::unique_ptr<ModelGateway> gateway_;
  std::atomic<int> in_flight_{0};
  std::atomic<bool> disposing_{false};
  std::atomic<bool> poisoned_{false};
  std::atomic<bool> dispose_failed_{false};
  mutable std::mutex idle_mutex_;
  mutable std::condition_variable idle_cv_;
  std::mutex write_gate_;
  mutable std::mutex browser_mutex_;
  BrowserSessionState browser_;
};

/// 上下文注册表：所有查找、创建、移除都在注册表锁内完成；表里只存共享引用。
class Registry {
 public:
  static Registry& instance();

  /// 查找或创建。`created` 非空时写入「这次是否新建了对象」。
  std::shared_ptr<Context> acquire(const std::string& name, bool* created);

  /// 创建结果：新建 / 已存在 / 同名正在销毁（最后一种不返回对象）。
  enum class CreateOutcome { Created, Existed, Disposing };
  CreateOutcome create(const std::string& name, std::shared_ptr<Context>* out);

  /// 只查找，不创建。
  std::shared_ptr<Context> find(const std::string& name);

  /// 从表里移除一个名字；返回被移除的对象（没有则空）。
  std::shared_ptr<Context> remove(const std::string& name);

  /// 测试用：清空注册表（不删 spill 目录，不删同名磁盘状态）。
  void clear_for_tests();

  std::size_t size() const;

 private:
  Registry() = default;
  mutable std::mutex mutex_;
  std::map<std::string, std::shared_ptr<Context>> map_;
};

/// 测试用：清空注册表并解绑当前线程。只清内存，不删 spill 目录 ——
/// 「进程重启后同名重建要继续编号」的用例靠这个钩子模拟重启。
void reset_registry_for_tests();

}  // namespace context

#endif  // CONTEXT_H
