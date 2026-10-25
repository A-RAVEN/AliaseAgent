#ifndef COMMAND_TOOL_H
#define COMMAND_TOOL_H

#include <string>
#include <vector>

/// `run_command` 工具：把一条 PowerShell 命令交给操作系统执行，把退出码、标准输出、
/// 标准错误还给调用方。
///
/// 三条硬规矩（设计与规范里的决策，改动前先读
/// `openspec/changes/add-command-tool/design.md` 的决策 1~5，以及
/// `openspec/changes/spill-large-tool-output/`）：
///   1. 命令字符串作为 `-Command` 的**单个** argv 元素交出去，外层不再套一层解析；
///   2. 对子进程**额外注入**环境变量而不是替换（PATH 必须留给子进程）；
///   3. 每条流的**完整输出先落盘**到 `~/.aliasagent/spill/<会话>/<序号>-<流>.txt`
///      （原子写），内存里保留头尾各 `preview_chars` 个字符并给出可取回的引用。
///
/// 请求 JSON：
///   {"command":"...",            // 必填，PowerShell 方言
///    "workdir":"...",            // 可选，缺省为当前工作区；越界拒绝
///    "timeout_ms":120000,        // 可选，毫秒；非法值回落缺省；超过上限按上限
///    "max_timeout_ms":600000,    // 可选，超时上限
///    "preview_chars":1000,       // 可选，头尾各留多少字符（配置键 spill.preview_chars）
///    "spill_session":"<会话 id>"} // 可选，决定 spill 子目录；缺省 no-session
///
/// 返回 JSON（成功执行，无论命令自身退出码是否为 0）：
///   {"ok":true,"exit_code":N,"timed_out":bool,"duration_ms":N,
///    "stdout":"...","stderr":"...",                       // 给模型看的那份
///    "truncated":{"stdout":bool,"stderr":bool},           // 是否只给了头尾
///    "spill":{"stdout":{"ref":"...","total_bytes":N,"omitted_bytes":N,
///                       "head":"...","tail":"..."}, "stderr":{...}}}
/// 工具自身无法执行、或输出超限又写不进 spill 时返回
/// {"ok":false,"error":"<中文可读说明>"}。
namespace command_tool {

/// 起进程时用的 argv。**单独暴露出来是为了能被断言**：规范要求"命令字符串作为
/// `-Command` 的单个参数、数组长度为 5"（`subprocess_test` 那条 6 元素的形状是
/// `subprocess` 层的事，这里只到工具层）。
/// 第 5 项必须是"编码前缀 + 命令的原文"拼成的**一个**字符串。
std::vector<std::string> build_invocation(const std::string& shell,
                                          const std::string& command);

std::string run_command(const std::string& request_json);

}  // namespace command_tool

#endif  // COMMAND_TOOL_H
