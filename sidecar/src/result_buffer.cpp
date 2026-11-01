#include "result_buffer.h"

#include <unordered_map>

namespace result_buffer {

namespace {

// 每个线程一张「槽 → 内容」表。键是 Slot 对象的地址（每个导出函数一个静态
// Slot，地址固定），所以同一线程里不同导出函数互不覆盖；不同线程各有一张表，
// 所以同一导出函数被两个线程并发调用也不会互相覆盖。
thread_local std::unordered_map<const Slot*, std::string> g_thread_slots;

Slot g_test_slots[64];

}  // namespace

const char* Slot::set(std::string text) {
  std::string& buf = storage();
  buf = std::move(text);
  return buf.c_str();
}

const std::string& Slot::get() const { return storage(); }

std::string& Slot::storage() const {
  // 用 this 作键：每个导出函数各有一个静态 Slot 实例。thread_local 表按线程分开。
  return g_thread_slots[this];
}

Slot& slot_at(int index) {
  if (index < 0) index = 0;
  if (index >= slot_count()) index = slot_count() - 1;
  return g_test_slots[index];
}

Slot& slot_for_tests(int index) { return slot_at(index); }

int slot_count() { return 64; }

}  // namespace result_buffer
