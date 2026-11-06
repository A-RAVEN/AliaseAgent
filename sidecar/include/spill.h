#ifndef SPILL_H
#define SPILL_H

// 工具输出的落盘与读回（change `spill-large-tool-output`）。
//
// 契约见 `openspec/changes/spill-large-tool-output/specs/tool-output-spill/spec.md`：
//   ① 每次产生文本输出的工具调用都先把**完整输出**写到
//      `~/.aliasagent/spill/<会话>/<调用序号>-<流>.txt`；
//   ② 写是原子的（先 `*.tmp` 再 rename），失败要能被调用方看见；
//   ③ 超长时给模型的是"头 preview_chars 个字符 + 省略说明 + 尾 preview_chars 个字符"，
//      中间那段靠 `read_spill` 按字节读回；
//   ④ `read_spill` 只允许读 spill 根目录里的文件。

#include <cstddef>
#include <string>

#include <nlohmann/json.hpp>

namespace context {
class Context;
}

namespace spill {

/// spill 根目录，原生分隔符：`<主目录>/.aliasagent/spill`。
std::string root();

/// 测试用：把根目录换掉（传空串恢复默认）。测试里要是把它指到一个**不可写**的
/// 位置来验"写盘失败可见"，落地时必须成对恢复。
void set_root_for_tests(const std::string& path);

/// 测试用：把**当前上下文**的 spill 调用序号清零，让文件名可预测。
void reset_call_seq_for_tests();

/// 测试用：让下一次（以及之后每次）写在写出这么多字节之后失败，用来模拟磁盘满 /
/// 中途出错。传 `kNoInjectedFailure`（默认）取消注入。
constexpr size_t kNoInjectedFailure = static_cast<size_t>(-1);
void set_fail_after_bytes_for_tests(size_t bytes);

/// 上下文名字到目录名的映射（路径安全、无损）：`[a-z0-9_-]` 原样保留，其余字节
/// 写成 `%XX`（大写十六进制）。大写字母必须编码掉 —— Windows 文件系统不区分
/// 大小写，`Agent-7` 与 `agent-7` 不能落到同一个目录。空名字落到 `no-session`
/// （`create_context` 本身拒绝空名字，这只是路径兜底）。
std::string session_dir_name(const std::string& session);

/// 某上下文 spill 目录的绝对路径（`<根>/<编码后的名字>`）。
std::string context_dir(const std::string& key);

/// 上下文创建时调用：扫描该目录已有 `NNNNNN-*.txt` 的最大序号并从此之后继续，
/// 避免进程重启后从 1 重来覆盖旧引用。
void initialize_sequence_for_context(context::Context& ctx);

/// 销毁上下文时调用：删除该上下文的 spill 目录（在途调用已排空之后）。
void remove_context_dir(const std::string& key);

/// 某次调用落盘后的完整路径（`<根>/<会话>/<序号>-<流>.txt`）。
std::string path_for(const std::string& session, const std::string& tag, unsigned seq);

/// 一次落盘的结果。`ok == false` 时 `error` 里同时含目录与系统报错文本。
struct Written {
    bool ok = false;
    std::string path;  // 引用（绝对路径，原生分隔符）
    std::string error;
    size_t bytes = 0;
};

/// 原子写：先写 `<最终名>.tmp`，成功后再 rename 到最终名；任何一步失败都删掉临时
/// 文件，最终名保持原状（要么是上一次的完整内容，要么根本不存在）。
///
/// 序号从**当前上下文**的原子计数器取（每上下文各一份）。
Written write(const std::string& session, const std::string& tag, const std::string& content);

/// 内部写入入口：显式接收上下文，从该上下文的原子计数器取号后落盘。
/// 它**不经过写闸门** —— 同一上下文的两个线程可以直接并发调用它，取到的序号必然
/// 不同（change add-context-handles 任务 1.5 的验收入口）。
Written write_for_context(context::Context& ctx, const std::string& session,
                          const std::string& tag, const std::string& content);

// ---------------------------------------------------------------------------
// 交付形状（change `migrate-web-fetch-to-spill`：从 `command_tool.cpp` 的提升）
// ---------------------------------------------------------------------------

/// 头尾各留多少字符（`preview_chars` 的缺省值）。用户 2026-10-25 的决定：原话
/// 「4000字听起来也好多，改成1000字吧」。可配，配置键 `spill.preview_chars`。
/// 判断"要不要省略"的阈值是它的 2 倍（头 + 尾），算术推论，不是第二个魔数。
///
/// 原先住在 `command_tool.cpp` 的匿名命名空间里（跨文件取不到），随形状实现一起
/// 提升到这里：`run_command` 与 `web_fetch` 的两个工具共读这一份，不再各写一个 1000。
inline constexpr long long kDefaultPreviewChars = 1000;

/// 一条流的交付形状（`run_command` 的 stdout/stderr 与 `web_fetch` 的 content 共用）。
///
/// 三条不变量（`spill-large-tool-output` 的判据就钉在这三条上）：
///   ① `head` / `tail` 是 spill 文件里的**原始字节切片**（只在码点边界落刀），
///      所以 `|head| + |tail| + omitted_bytes == total_bytes` 恒成立；
///   ② 给模型看的 `inline_text` 由 `sanitize_utf8(head/tail)` 拼出来 —— 换行归一
///      与坏字节替换**只发生在这一步**，不落到文件上；
///   ③ `ref` 就是那个文件的绝对路径，`read_spill` 能按字节读回中间段。
struct StreamShape {
  std::string inline_text;  // 交给模型的那份
  bool truncated = false;
  nlohmann::json envelope =
      nlohmann::json::object();  // {ref,total_bytes,omitted_bytes,head,tail}
};

/// 把一条流先落盘，再按 `preview_chars × 2` 决定内联全文还是头尾 + 引用。
///
/// 落盘失败时不返回 `ok:false` —— 由调用方按"输出是否超过预览阈值"决定兜底方式
/// （小的直接内联，大的必须报错，见规范"写盘失败必须可见"）。
StreamShape shape_stream(context::Context& ctx, const std::string& raw, size_t preview_chars,
                         const std::string& session, const char* tag, Written* written_out);

/// 严格 UTF-8 校验：拒绝过长编码、代理区、超出 U+10FFFF、以及被截断的尾巴。
bool is_valid_utf8(const std::string& s);

/// 字符数（按 UTF-8 码点计，不是字节数）。非法字节各算一个字符。
size_t char_count(const std::string& s);

/// 按码点取头部 / 尾部 n 个字符。n 不小于总数时原样返回。两个方向都**不会**把
/// 一个多字节字符切成半个（只能在码点边界落刀）。
std::string head_chars(const std::string& s, size_t n);
std::string tail_chars(const std::string& s, size_t n);

/// `read_spill` 的 FFI 入口实现：入参 `{"ref":…,"offset":…,"limit":…}`，返回 JSON。
/// 引用必须先按平台规范化，再只接受**该上下文自己的目录**里的文件；别的上下文
/// （含 `<乙>/../<甲>/文件`）一律拒绝。
std::string read_request(const context::Context& ctx, const std::string& request_json);

}  // namespace spill

#endif  // SPILL_H
