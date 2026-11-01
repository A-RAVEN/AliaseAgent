#ifndef RESULT_BUFFER_H
#define RESULT_BUFFER_H

// 导出函数的返回字符串槽（change `add-context-handles`，design 决策 4）。
//
// 为什么按「调用线程」而不是按上下文分：同一个上下文也可能被两个线程并发调用，
// 而 Dart 是在 FFI 调用的**返回之后**才执行 toDartString()；即使调用期间持锁，
// 函数返回时锁就已释放，另一个线程仍可能在这段时间改写同一份 std::string。
// 所以每个导出函数持有自己的 Slot，Slot 里的内容按线程各存一份。
//
// 这个源码单元同时编进 sidecar.dll 与 sidecar_tests：sidecar_tests 不链接
// sidecar_api.cpp（避免 dllimport 冲突），不给它这份实现，测试就碰不到返回缓冲。

#include <string>

namespace result_buffer {

/// 一个导出函数专用、按调用线程各一份的返回字符串槽。
/// 返回的指针在下一次同一线程调用同一个 Slot 之前有效；调用方必须立即复制。
class Slot {
 public:
  /// 把 text 放进当前线程的槽，返回指向它的指针。
  const char* set(std::string text);

  /// 当前线程槽里的内容（测试用；导出函数不读它）。
  const std::string& get() const;

 private:
  std::string& storage() const;
};

/// 按编号取一个独占的槽。导出函数各用固定编号（见 context_api.cpp 的
/// SlotId），`sidecar_api.cpp` 与 `context_api.cpp` 因此拿到同一份线程本地存储。
Slot& slot_at(int index);

/// 测试用：同 slot_at（保留这个名字，让测试一眼看出这是测试入口）。
Slot& slot_for_tests(int index);

/// 槽的总数（64 个：18 个结果缓冲 + 11 个异常槽 + create/dispose/cancel 之后
/// 还有余量）。
int slot_count();

}  // namespace result_buffer

#endif  // RESULT_BUFFER_H
