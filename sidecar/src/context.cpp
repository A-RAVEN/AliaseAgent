#include "context.h"

#include <utility>

#include "model_gateway.h"

namespace context {

namespace {

thread_local Context* g_bound = nullptr;

}  // namespace

Context::Context(std::string name) : name_(std::move(name)) {}

Context::~Context() = default;

std::string Context::workspace() const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  return workspace_;
}

void Context::set_workspace_value(std::string value) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  workspace_ = std::move(value);
}

bool Context::observed_version(const std::string& path, FileVersion& out) const {
  std::lock_guard<std::mutex> lock(state_mutex_);
  const int active = observed_active_.fetch_add(1, std::memory_order_acq_rel) + 1;
  int seen = observed_max_active_.load(std::memory_order_relaxed);
  while (active > seen &&
         !observed_max_active_.compare_exchange_weak(seen, active, std::memory_order_relaxed)) {
  }
  const int pause_ms = observation_pause_ms_.load(std::memory_order_relaxed);
  if (pause_ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(pause_ms));
  const auto it = observed_.find(path);
  const bool found = it != observed_.end();
  if (found) out = it->second;
  observed_active_.fetch_sub(1, std::memory_order_acq_rel);
  return found;
}

void Context::record_observation(const std::string& path, const FileVersion& version) {
  std::lock_guard<std::mutex> lock(state_mutex_);
  const int active = observed_active_.fetch_add(1, std::memory_order_acq_rel) + 1;
  int seen = observed_max_active_.load(std::memory_order_relaxed);
  while (active > seen &&
         !observed_max_active_.compare_exchange_weak(seen, active, std::memory_order_relaxed)) {
  }
  const int pause_ms = observation_pause_ms_.load(std::memory_order_relaxed);
  if (pause_ms > 0) std::this_thread::sleep_for(std::chrono::milliseconds(pause_ms));
  observed_[path] = version;
  observed_active_.fetch_sub(1, std::memory_order_acq_rel);
}

void Context::reset_observations() {
  std::lock_guard<std::mutex> lock(state_mutex_);
  observed_.clear();
}

void Context::set_observation_pause_for_tests(int milliseconds) {
  observation_pause_ms_.store(milliseconds, std::memory_order_relaxed);
}

int Context::observed_max_concurrent_for_tests() const {
  return observed_max_active_.load(std::memory_order_acquire);
}

void Context::reset_observed_max_concurrent_for_tests() {
  observed_max_active_.store(0, std::memory_order_release);
}

unsigned Context::next_spill_seq() { return ++spill_seq_; }

void Context::reset_spill_seq_for_tests() { spill_seq_.store(0, std::memory_order_relaxed); }

void Context::raise_spill_seq_floor(unsigned max_seq) {
  unsigned current = spill_seq_.load(std::memory_order_relaxed);
  while (current < max_seq &&
         !spill_seq_.compare_exchange_weak(current, max_seq, std::memory_order_relaxed)) {
  }
}

unsigned Context::peek_spill_seq() const {
  return spill_seq_.load(std::memory_order_relaxed);
}

ModelGateway& Context::gateway() {
  std::lock_guard<std::mutex> lock(gateway_mutex_);
  if (!gateway_) gateway_ = std::make_unique<ModelGateway>();
  return *gateway_;
}

void Context::enter() { in_flight_.fetch_add(1, std::memory_order_acq_rel); }

void Context::leave() {
  in_flight_.fetch_sub(1, std::memory_order_acq_rel);
  // 在途计数归零时唤醒销毁线程（drain 等待）。
  std::lock_guard<std::mutex> lock(idle_mutex_);
  idle_cv_.notify_all();
}

int Context::in_flight() const { return in_flight_.load(std::memory_order_acquire); }

void Context::mark_disposing() { disposing_.store(true, std::memory_order_release); }

bool Context::try_mark_disposing() {
  bool expected = false;
  return disposing_.compare_exchange_strong(expected, true, std::memory_order_acq_rel);
}

bool Context::disposing() const { return disposing_.load(std::memory_order_acquire); }

void Context::wait_for_idle() {
  std::unique_lock<std::mutex> lock(idle_mutex_);
  idle_cv_.wait(lock, [this]() { return in_flight_.load(std::memory_order_acquire) == 0; });
}

void Context::cancel_model_if_any() {
  std::lock_guard<std::mutex> lock(gateway_mutex_);
  if (gateway_) gateway_->cancel();
}

void Context::mark_poisoned() { poisoned_.store(true, std::memory_order_release); }

bool Context::poisoned() const { return poisoned_.load(std::memory_order_acquire); }

void Context::mark_dispose_failed() { dispose_failed_.store(true, std::memory_order_release); }

bool Context::dispose_failed() const {
  return dispose_failed_.load(std::memory_order_acquire);
}

BrowserSessionState Context::browser_state() const {
  std::lock_guard<std::mutex> lock(browser_mutex_);
  return browser_;
}

void Context::set_browser_session(bool has_session, std::uint64_t generation) {
  std::lock_guard<std::mutex> lock(browser_mutex_);
  browser_.has_session = has_session;
  browser_.generation = generation;
  browser_.allow_reopen = false;
}

void Context::clear_browser_session() {
  std::lock_guard<std::mutex> lock(browser_mutex_);
  browser_.has_session = false;
  browser_.allow_reopen = false;
}

void Context::set_allow_reopen(bool allow) {
  std::lock_guard<std::mutex> lock(browser_mutex_);
  browser_.allow_reopen = allow;
}

bool Context::allow_reopen() const {
  std::lock_guard<std::mutex> lock(browser_mutex_);
  return browser_.allow_reopen;
}

Context* Context::bound() { return g_bound; }

Context* Context::bind(Context* value) {
  Context* previous = g_bound;
  g_bound = value;
  return previous;
}

Context& Context::current() {
  if (g_bound) return *g_bound;
  return implicit();
}

Context& Context::implicit() {
  // 进程内唯一。它只接住「没有显式绑定上下文」的内部调用；导出函数每一步都会
  // 先按句柄解析上下文再调用 context_api，绝不走这条兜底路径。
  static Context instance("_implicit");
  return instance;
}

Registry& Registry::instance() {
  static Registry registry;
  return registry;
}

std::shared_ptr<Context> Registry::acquire(const std::string& name, bool* created) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = map_.find(name);
  if (it != map_.end()) {
    if (created) *created = false;
    return it->second;
  }
  auto ctx = std::make_shared<Context>(name);
  map_[name] = ctx;
  if (created) *created = true;
  return ctx;
}

Registry::CreateOutcome Registry::create(const std::string& name,
                                         std::shared_ptr<Context>* out) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = map_.find(name);
  if (it != map_.end()) {
    // 同名正在销毁：不许新旧并存，必须让调用方看到 context_disposing。
    if (it->second->disposing()) {
      if (out) out->reset();
      return CreateOutcome::Disposing;
    }
    if (out) *out = it->second;
    return CreateOutcome::Existed;
  }
  auto ctx = std::make_shared<Context>(name);
  map_[name] = ctx;
  if (out) *out = ctx;
  return CreateOutcome::Created;
}

std::shared_ptr<Context> Registry::find(const std::string& name) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = map_.find(name);
  return it == map_.end() ? std::shared_ptr<Context>() : it->second;
}

std::shared_ptr<Context> Registry::remove(const std::string& name) {
  std::lock_guard<std::mutex> lock(mutex_);
  const auto it = map_.find(name);
  if (it == map_.end()) return std::shared_ptr<Context>();
  std::shared_ptr<Context> ctx = it->second;
  map_.erase(it);
  return ctx;
}

void Registry::clear_for_tests() {
  std::lock_guard<std::mutex> lock(mutex_);
  map_.clear();
}

std::size_t Registry::size() const {
  std::lock_guard<std::mutex> lock(mutex_);
  return map_.size();
}

void reset_registry_for_tests() {
  Registry::instance().clear_for_tests();
  Context::bind(nullptr);
}

}  // namespace context
