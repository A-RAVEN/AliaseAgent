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

namespace spill {

/// spill 根目录，原生分隔符：`<主目录>/.aliasagent/spill`。
std::string root();

/// 测试用：把根目录换掉（传空串恢复默认）。测试里要是把它指到一个**不可写**的
/// 位置来验"写盘失败可见"，落地时必须成对恢复。
void set_root_for_tests(const std::string& path);

/// 测试用：清空调用序号，让文件名可预测。
void reset_call_seq_for_tests();

/// 测试用：让下一次（以及之后每次）写在写出这么多字节之后失败，用来模拟磁盘满 /
/// 中途出错。传 `kNoInjectedFailure`（默认）取消注入。
constexpr size_t kNoInjectedFailure = static_cast<size_t>(-1);
void set_fail_after_bytes_for_tests(size_t bytes);

/// 会话名到目录名的映射（路径安全）：只留 `[A-Za-z0-9._-]`，其余换成 `_`；
/// 纯 `.` / `..` / 空串一律落到 `no-session`。**Dart 侧删除会话目录时必须用同一套
/// 规则**（`lib/services/spill_paths.dart` 里那份是镜像，改这里就要同步改那里）。
std::string session_dir_name(const std::string& session);

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
Written write(const std::string& session, const std::string& tag, const std::string& content);

/// 严格 UTF-8 校验：拒绝过长编码、代理区、超出 U+10FFFF、以及被截断的尾巴。
bool is_valid_utf8(const std::string& s);

/// 字符数（按 UTF-8 码点计，不是字节数）。非法字节各算一个字符。
size_t char_count(const std::string& s);

/// 按码点取头部 / 尾部 n 个字符。n 不小于总数时原样返回。两个方向都**不会**把
/// 一个多字节字符切成半个（只能在码点边界落刀）。
std::string head_chars(const std::string& s, size_t n);
std::string tail_chars(const std::string& s, size_t n);

/// `read_spill` 的 FFI 入口实现：入参 `{"ref":…,"offset":…,"limit":…}`，返回 JSON。
std::string read_request(const std::string& request_json);

}  // namespace spill

#endif  // SPILL_H
