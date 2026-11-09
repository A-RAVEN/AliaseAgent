#ifndef SKILL_TOOL_H
#define SKILL_TOOL_H

// `load_skill` 的 C++ 实现面（change `add-skill-mechanism` 任务 4.1 / 4.2）。
//
// 职责（design D1 / D5 / D6）：
//   - 技能名先按规范字符集校验（`Docs/AgentSkillsDoc.md` 第一节 `name` 规则）；
//   - 根路径 = `<主目录>/.aliasagent/skills`，主目录解析与 `spill.cpp` 的
//     `home_dir()` 同源（Windows 取 `USERPROFILE`）；
//   - 不带 `file` 读 `SKILL.md` 并按 design D2 切除 frontmatter（只做行切，不解析
//     YAML 语义）；带 `file` 读技能目录内的附属文件全文（**不**切除任何段落）；
//   - `file` 参数拼接后按平台规范化，结果必须仍在该技能目录内（`..`、绝对路径、
//     盘符改写一律拒）；
//   - 交付形状复用共享实现 `spill::shape_stream`（落盘 tag = `skill`），写盘失败时
//     按 `tool-output-spill` 能力「写盘失败必须可见」处理。

#include <string>

#include <nlohmann/json.hpp>

namespace context {
class Context;
}

namespace skill_tool {

/// 技能根目录（原生分隔符）：`<主目录>/.aliasagent/skills`。
std::string root();

/// 测试用：把技能根换掉（传空串恢复默认）。与 `spill::set_root_for_tests` 同形，
/// 落地时成对恢复。
void set_root_for_tests(const std::string& path);

/// 按 design D2 切除 frontmatter：`SKILL.md` 首行恰为 `---` 才算有 frontmatter，切到
/// 下一个**独立成行**的 `---`；不满足（首行不是 `---`，或有开头没闭合行）时整个文件
/// 都是正文。与 Dart 侧 `lib/services/skills/skill_frontmatter.dart` 的 `splitSkillMd`
/// 同规，两侧用同一份夹具互验（`sidecar/test/fixtures/skills/edge-skill/SKILL.md`）。
std::string strip_frontmatter(const std::string& raw);

/// 技能名的规范字符集校验（`Docs/AgentSkillsDoc.md` 第一节 `name` 字段规则）：
/// 1–64 字节，仅小写字母、数字与单个 `-` 分隔，不以 `-` 开头或结尾，不含连续 `--`。
/// 字符集本身排除了 `.` `/` `\`，所以不合规的名字不会碰到文件系统。
bool is_valid_skill_name(const std::string& name);

/// `load_skill` 的主体。
///
/// @param request_json  {"skill":"<名字>","file":"<可选,相对技能目录>",
///                       "preview_chars":<头尾各留多少字符，缺省 spill::kDefaultPreviewChars>}
/// @return JSON：
///   成功  {"ok":true,"content":"<形状后的内联文本>","truncated":bool,
///          "spill":{"skill":{"ref":…,"total_bytes":N,"omitted_bytes":N,"head":…,"tail":…}}}
///   失败  {"ok":false,"error":"<含技能名与路径的中文原因>"}
/// 文件不存在 / 技能目录不存在一律 `ok:false`，SHALL NOT 返回空内容冒充成功。
std::string load_skill(context::Context& ctx, const std::string& request_json);

}  // namespace skill_tool

#endif  // SKILL_TOOL_H
