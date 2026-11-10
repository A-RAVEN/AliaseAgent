// 斜杠命令展开（change `add-slash-commands` 任务 1.1；design D2 / D3 / D4）。
//
// 定位：这是**模型装配面**用的纯函数 —— 只回答"这条用户文本该发给模型什么"。
// 它不读盘、不读单例、不落库、不产生任何界面。落库 / 会话标题 / 对话视图气泡全部
// 发生在装配之前（`lib/services/agent.dart` 的 `_sendMessageRound`），所以它们
// 永远是用户手打原文；只有 `_buildApiMessages` 的 user 文本块走这里。
//
// 判定规则（design D2，规范「用户消息的斜杠技能展开」）：
//   - 空串直接透传、不做首字符判定（只有图片附件的历史消息就是空串）；
//   - 首字符必须是 `/`；
//   - 首段 = 斜杠之后到首个空白字符或文本末尾为止；空白字符的集合**钉死**为
//     U+0020 空格 / U+0009 制表 / U+000A 换行 —— 全角空格 U+3000 不算空白，
//     所以 `/edge-skill　正文` 的首段是整段文本，不命中；
//   - 首段与当轮生效技能名**逐字**相等才展开（大小写不一致 = 不命中；技能名受
//     `skill_frontmatter.dart` 的校验约束只含小写字母/数字/连字符）；
//   - 未命中一律原样返回入参：透传语义写在返回值里，调用方无条件使用返回值，
//     不需要任何判断。

/// 斜杠字符 `/` 的 UTF-16 码元。
const int _kSlashUnit = 0x2F;

/// 空白的三个码元（design D2 钉死的集合，不许扩：U+3000 全角空格刻意不算）。
const int _kSpaceUnit = 0x20;
const int _kTabUnit = 0x09;
const int _kLineFeedUnit = 0x0A;

/// 命中斜杠命令时的固定前缀句模板（design D3：单个固定常量，不开放配置）。
///
/// **出处 = `openspec/changes/add-slash-commands/tasks.md` 任务 1.1**（精确措辞以该
/// 任务为准）。`<name>` 是技能名占位符（技能名只含小写字母/数字/连字符，不会与
/// 占位符本身冲突）。
///
/// 模板形态钉死为：**本前缀句 + "\n\n" + 余下正文**；空正文时文本止于前缀句后的
/// 两个换行。改措辞必须同步本注释、`test/unit/slash_commands_test.dart` 的整段逐字
/// 断言与 `Docs/user-guide/slash-commands.md` 三处（spec 的硬要求）。
const String _kExpansionPrefixTemplate =
    '已按斜杠命令展开技能 "<name>"：请先调用 load_skill(skill: "<name>") 读取该技能说明并严格遵循其中的指令，然后处理下面的请求：';

/// 把一条用户消息文本按斜杠技能规则展开（纯函数、幂等、零 IO、零状态）。
///
/// - 命中：返回 [前缀句插好技能名][两个换行][余下正文]；余下正文可为空串。
/// - 未命中：**原样返回 [text]**（同一个字符串内容，不做 trim、不改写）。
///
/// [activeSkillNames] 是**当轮**生效技能名集合；调用方负责在本次装配开始时取一次
/// 并复用（`SkillCatalogService.instance.activeSkillNames`）。本函数不缓存、不读单例。
String expandSlashCommand(String text, List<String> activeSkillNames) {
  // 空串直接透传：这条路径对应只有图片附件的历史消息，连首字符判定都不做。
  if (text.isEmpty) return text;
  if (text.codeUnitAt(0) != _kSlashUnit) return text;

  // 首段：斜杠之后到首个空白码元（或文本末尾）为止。
  var end = 1;
  while (end < text.length) {
    final unit = text.codeUnitAt(end);
    if (unit == _kSpaceUnit || unit == _kTabUnit || unit == _kLineFeedUnit) {
      break;
    }
    end++;
  }
  final name = text.substring(1, end);

  // 空首段（如 `/ 正文`）不可能是任何生效技能名；逐字匹配、大小写敏感。
  if (name.isEmpty || !activeSkillNames.contains(name)) return text;

  // 余下正文 = 首段之后**跳过一个空白**的剩余文本（可为空）。
  final rest = end < text.length ? text.substring(end + 1) : '';

  return '${_kExpansionPrefixTemplate.replaceAll('<name>', name)}\n\n$rest';
}
