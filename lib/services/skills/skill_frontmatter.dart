// `SKILL.md` 的 frontmatter 切除与规范六字段校验（change `add-skill-mechanism`
// 任务 1.2，规则出处 design D2 与 `Docs/AgentSkillsDoc.md` 第一节字段表）。
//
// 两侧同规（design D2）：本文件的切除规则与 C++ 侧 `sidecar/src/skill_tool.cpp`
// 的 `strip_frontmatter` 必须行为一致 —— 首行恰为 `---` 才算有 frontmatter，切到
// 下一个**独立成行**的 `---`；不满足则整个文件按正文处理（判定"无 frontmatter"）。
// 两侧用同一份夹具 `sidecar/test/fixtures/skills/edge-skill.md` 互验（Dart 侧
// `test/unit/skill_frontmatter_test.dart`、C++ 侧 `sidecar/test/skill_tool_test.cpp`）。
//
// 字段硬限 64 / 1024 / 500 的出处是 `Docs/AgentSkillsDoc.md` 第一节的规范字段表
// （"1–64 字符" / "1–1024 字符，非空" / "若提供则 1–500 字符"），不是本项目自造的
// 数字；本文件不新增任何数量上限。
library;

import 'package:yaml/yaml.dart';

/// frontmatter 的定界行。按规范它是一个**独立成行**的 `---`（前后无别的字符）。
const String kSkillFrontmatterDelimiter = '---';

/// `name` 的字符数上限（`Docs/AgentSkillsDoc.md` 第一节字段表：1–64 字符）。
const int kSkillNameMaxChars = 64;

/// `description` 的字符数上限（同上：1–1024 字符）。
const int kSkillDescriptionMaxChars = 1024;

/// `compatibility` 的字符数上限（同上：若提供则 1–500 字符）。
const int kSkillCompatibilityMaxChars = 500;

/// `name` 的字符合法集合：仅小写字母、数字与**单个**连字符分隔，
/// 不以 `-` 开头或结尾、不含连续 `--`。
final RegExp _kSkillNamePattern = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');

/// 一行文本（保留原始起止偏移）。
class _RawLine {
  const _RawLine({
    required this.text,
    required this.start,
    required this.afterNewline,
  });

  /// 该行内容（不含换行符，可能以 `\r` 结尾 —— CRLF 文件）。
  final String text;

  /// 该行第一个字节在原文里的下标。
  final int start;

  /// 该行**含**换行符之后的下标（即下一行起点；最后一行无换行时 == 原文长度）。
  final int afterNewline;
}

/// 按 `\n` 切行并保留每行的原始偏移（不改变换行符本身）。
List<_RawLine> _splitLines(String raw) {
  final lines = <_RawLine>[];
  var start = 0;
  while (start < raw.length) {
    final newline = raw.indexOf('\n', start);
    if (newline < 0) {
      lines.add(_RawLine(text: raw.substring(start), start: start, afterNewline: raw.length));
      break;
    }
    lines.add(_RawLine(
      text: raw.substring(start, newline),
      start: start,
      afterNewline: newline + 1,
    ));
    start = newline + 1;
  }
  return lines;
}

/// 去掉行尾的 `\r`（CRLF 文件里定界行是 `---\r`，仍算独立成行的 `---`）。
String _withoutCarriageReturn(String line) =>
    line.endsWith('\r') ? line.substring(0, line.length - 1) : line;

/// 一份 `SKILL.md` 的切除结果。
class SkillMdSplit {
  const SkillMdSplit({
    required this.hasFrontmatter,
    required this.frontmatterText,
    required this.body,
  });

  /// 首行恰为 `---` 且能找到闭合的独立 `---` 行。
  final bool hasFrontmatter;

  /// 两个定界行**之间**的原文（不含定界行本身）。无 frontmatter 时为空串。
  final String frontmatterText;

  /// 闭合 `---` 行之后的原文（正文）。无 frontmatter 时是**整个文件**。
  final String body;
}

/// 按 design D2 切除 frontmatter。C++ 侧同规实现见 `sidecar/src/skill_tool.cpp`。
SkillMdSplit splitSkillMd(String raw) {
  final lines = _splitLines(raw);
  if (lines.isEmpty ||
      _withoutCarriageReturn(lines.first.text) != kSkillFrontmatterDelimiter) {
    return SkillMdSplit(hasFrontmatter: false, frontmatterText: '', body: raw);
  }
  final openEnd = lines.first.afterNewline;
  for (var i = 1; i < lines.length; i++) {
    if (_withoutCarriageReturn(lines[i].text) != kSkillFrontmatterDelimiter) {
      continue;
    }
    return SkillMdSplit(
      hasFrontmatter: true,
      frontmatterText: raw.substring(openEnd, lines[i].start),
      body: raw.substring(lines[i].afterNewline),
    );
  }
  // 只有开头的 `---` 而没有闭合行：按"无 frontmatter"处理（整个文件都是正文）。
  return SkillMdSplit(hasFrontmatter: false, frontmatterText: '', body: raw);
}

/// 校验通过的技能元数据（规范六字段里本产品会用的那几项 + 正文）。
class SkillFields {
  const SkillFields({
    required this.name,
    required this.description,
    required this.body,
    this.compatibility,
    this.license,
    this.metadata,
    this.allowedTools,
  });

  /// `name`（规范要求与父目录名一致，校验时已比对）。
  final String name;

  /// `description`（原样保存，不截断不改写 —— 规范字段硬限已在校验处把关）。
  final String description;

  /// 切除 frontmatter 后的正文（`load_skill` 不加 `file` 时返回的就是它）。
  final String body;

  final String? compatibility;
  final String? license;

  /// `metadata`：字符串键 → 值；本产品不使用，仅原样保留。
  final Map<String, Object?>? metadata;

  /// `allowed-tools`：规范里的空格分隔工具名串；本产品零审批，**不**据此预批准。
  final String? allowedTools;
}

/// 一次校验的结果：成功带 [fields]，失败带可进日志与用户提示的 [error]。
class SkillValidation {
  const SkillValidation.ok(SkillFields this.fields) : error = null;

  const SkillValidation.failure(String this.error) : fields = null;

  final SkillFields? fields;

  /// 失败原因（中文、含具体数值与出处口径，例如 "name 超过 64 字符（实际 65）"）。
  final String? error;

  bool get ok => error == null;
}

int _charCount(String value) => value.runes.length;

/// 按 `Docs/AgentSkillsDoc.md` 第一节字段表校验一份 `SKILL.md`。
///
/// [directoryName] 是技能目录名（`<skills 根>/<目录名>/SKILL.md` 里的那个目录名）：
/// 规范要求 `name` 与它**完全一致**。
///
/// 校验失败一律返回 [SkillValidation.failure]，不抛异常（调用方要把失败原因汇总成
/// 一行可见提示，抛异常会丢掉"哪个技能、为什么"）。
SkillValidation validateSkillMd({
  required String raw,
  required String directoryName,
}) {
  final split = splitSkillMd(raw);
  if (!split.hasFrontmatter) {
    return const SkillValidation.failure(
        '没有 frontmatter：SKILL.md 首行必须是独立成行的 `---`，并以下一个独立 `---` 行闭合');
  }

  final Object? document;
  try {
    document = loadYaml(split.frontmatterText);
  } on YamlException catch (e) {
    return SkillValidation.failure('frontmatter 不是合法的 YAML：${e.message}');
  } catch (e) {
    return SkillValidation.failure('frontmatter 不是合法的 YAML：$e');
  }
  if (document is! Map) {
    return const SkillValidation.failure('frontmatter 必须是一组键值对（YAML 映射）');
  }
  final Map<Object?, Object?> map = document;

  // ---- name：必填、1–64、字符集、与父目录名一致 ----
  final Object? rawName = map['name'];
  if (rawName == null) {
    return const SkillValidation.failure(
        '缺少必填字段 name（规范：1–64 字符，且须与父目录名一致）');
  }
  if (rawName is! String) {
    return const SkillValidation.failure('name 必须是字符串');
  }
  if (rawName.isEmpty) {
    return const SkillValidation.failure('name 不能为空（规范：1–64 字符）');
  }
  if (_charCount(rawName) > kSkillNameMaxChars) {
    return SkillValidation.failure(
        'name 超过 $kSkillNameMaxChars 字符（实际 ${_charCount(rawName)}）："$rawName"');
  }
  if (!_kSkillNamePattern.hasMatch(rawName)) {
    return SkillValidation.failure(
        'name 只能由小写字母、数字与单个连字符组成，且不得以 "-" 开头或结尾、'
        '不得含连续 "--"："$rawName"');
  }
  if (rawName != directoryName) {
    return SkillValidation.failure(
        'name 与父目录名不一致（目录 "$directoryName"，name "$rawName"）');
  }

  // ---- description：必填、1–1024 非空 ----
  final Object? rawDescription = map['description'];
  if (rawDescription == null) {
    return const SkillValidation.failure(
        '缺少必填字段 description（规范：1–1024 字符，非空）');
  }
  if (rawDescription is! String) {
    return const SkillValidation.failure('description 必须是字符串');
  }
  if (rawDescription.trim().isEmpty) {
    return const SkillValidation.failure(
        'description 不能为空（规范：1–1024 字符，非空）');
  }
  if (_charCount(rawDescription) > kSkillDescriptionMaxChars) {
    return SkillValidation.failure(
        'description 超过 $kSkillDescriptionMaxChars 字符（实际 ${_charCount(rawDescription)}）');
  }

  // ---- compatibility：可选；提供了就必须是 1–500（空串 = 失败）----
  String? compatibility;
  final Object? rawCompatibility = map['compatibility'];
  if (rawCompatibility != null) {
    if (rawCompatibility is! String) {
      return const SkillValidation.failure('compatibility 必须是字符串');
    }
    if (rawCompatibility.isEmpty) {
      return const SkillValidation.failure(
          'compatibility 提供了空串（规范：若提供则 1–500 字符）');
    }
    if (_charCount(rawCompatibility) > kSkillCompatibilityMaxChars) {
      return SkillValidation.failure(
          'compatibility 超过 $kSkillCompatibilityMaxChars 字符'
          '（实际 ${_charCount(rawCompatibility)}）');
    }
    compatibility = rawCompatibility;
  }

  // ---- license / metadata / allowed-tools：可选，本产品不据此改变行为 ----
  final Object? rawLicense = map['license'];
  final String? license = rawLicense is String ? rawLicense : null;

  Map<String, Object?>? metadata;
  final Object? rawMetadata = map['metadata'];
  if (rawMetadata is Map) {
    metadata = <String, Object?>{
      for (final entry in rawMetadata.entries) '${entry.key}': entry.value,
    };
  }

  final Object? rawAllowedTools = map['allowed-tools'];
  final String? allowedTools =
      rawAllowedTools is String ? rawAllowedTools : null;

  // 规范六字段之外的键（如 Claude Code 的 `context: fork`）忽略，不因此判失败。

  return SkillValidation.ok(SkillFields(
    name: rawName,
    description: rawDescription,
    body: split.body,
    compatibility: compatibility,
    license: license,
    metadata: metadata,
    allowedTools: allowedTools,
  ));
}
