// 斜杠命令**技能名补全**的纯逻辑与面板（change `slash-command-completion`）。
//
// 分工：
//   - 本文件装"匹配 + 首段判据 + 面板外观"；
//   - **状态机与按键接线住在 `lib/ui/input_bar.dart` 的 `_InputBarState`**
//     （design D2：只有那一层能先于既有 Enter→发送分支拿到按键，main.dart 里
//     没有 TextField）。本文件不读 `SkillCatalogService`，也不持有任何跨帧状态。
//
// 任务 1.1 = 匹配纯函数；任务 3.1 = 面板组件（Overlay + LayerLink）。
library;

import 'package:flutter/material.dart';

/// 空技能目录时的一行空态提示（精确串，spec「空目录空态提示」）。
///
/// 文案取向（design D5 / Risks）：中性信息色、不装成报错，并告诉用户怎么让它出现。
/// 改这里必须同步 `Docs/user-guide/slash-commands.md`（文档守卫会核对两处一致）。
const String kSlashCompletionEmptyCatalogHint =
    '装一个技能后这里会自动出现候选（详见 skills.md）';

/// 有技能、但当前查询一个都没命中时的一行提示（精确串，spec「无命中」）。
const String kSlashCompletionNoMatchHint = '无匹配技能';

/// 面板底边与输入框顶边之间的视觉间距（像素）。
///
/// **不是上下限**：与 `input_bar.dart` 里既有的 `SizedBox(width: 6)` 同一套界面
/// 间距，只用来让浮层不贴着输入框边线。
const double kSlashCompletionGap = 6;

/// 括号里那个 `skills.md` 指向的用户文档（文案里只写文件名，这里留一处完整路径给
/// 文档守卫核对"文件名不是随手编的"）。
const String kSlashCompletionSkillsDocPath = 'Docs/user-guide/skills.md';

/// 空白三码元（design D1 钉死的集合，与 `lib/services/slash_commands.dart` 的私有
/// 常量同一集合；**U+3000 全角空格刻意不算**，所以 `/ed　正文` 的首段是整段文本）。
const int _kSpaceUnit = 0x20;
const int _kTabUnit = 0x09;
const int _kLineFeedUnit = 0x0A;

/// 首段结束下标 = 首个空白码元的下标；文本里没有空白时为 `text.length`。
///
/// 首段 = 斜杠之后到 [slashFirstSegmentEnd] 为止（design D1）。调用方负责先确认
/// 文本以 `/` 开头 —— 本函数只回答"第一段在哪里结束"。
int slashFirstSegmentEnd(String text) {
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit == _kSpaceUnit ||
        unit == _kTabUnit ||
        unit == _kLineFeedUnit) {
      return i;
    }
  }
  return text.length;
}

/// 按查询串筛选并排序技能名（design D3）。
///
/// 排序骨架**借鉴** DSH `dsh-client-ui-commands` 的 fuzzy-label
/// （前缀 → 对齐分 → 原始顺序）：本实现**有意不移植对齐分**，简化为
/// 前缀 → 首次命中位置 → 输入顺序。技能名是短串（≤ `kSkillNameMaxChars`），
/// 更少的排序逻辑足够，而且"为什么排这儿"一眼可核。
///
/// - [query] 为空 ⇒ 按 [names] 的输入顺序全量返回（`activeSkillNames` 本身已按
///   字典序，生产观感就是字典序）；
/// - 否则：不区分大小写的**按序子序列**匹配（按序不必相邻，`/egk` 命中
///   `edge-skill`）；前缀命中排最前，其余按首次命中字符的下标；同分保持输入顺序
///   （Dart 的 `List.sort` 不稳定，所以必须显式兜底）；
/// - 无命中 ⇒ 空列表（不是 null、不是原列表）。
///
/// 纯函数：零 IO、零状态、不修改入参。
List<String> filterSkillNames(String query, List<String> names) {
  if (query.isEmpty) return List<String>.of(names);
  final needle = query.toLowerCase();
  final matches = <_SkillNameMatch>[];
  for (var i = 0; i < names.length; i++) {
    final name = names[i];
    final haystack = name.toLowerCase();
    final firstHit = _subsequenceFirstHit(needle, haystack);
    if (firstHit == null) continue;
    matches.add(_SkillNameMatch(
      index: i,
      name: name,
      firstHit: firstHit,
      isPrefix: haystack.startsWith(needle),
    ));
  }
  matches.sort((a, b) {
    if (a.isPrefix != b.isPrefix) return a.isPrefix ? -1 : 1;
    final byPosition = a.firstHit.compareTo(b.firstHit);
    if (byPosition != 0) return byPosition;
    return a.index.compareTo(b.index);
  });
  return [for (final match in matches) match.name];
}

/// 命中下标（排序用）与名字。
///
/// 用记录类型而不是三元素列表：字段名在排序闭包里直接可读，位置写反了不会被
/// `int` 静默接住。
class _SkillNameMatch {
  const _SkillNameMatch({
    required this.index,
    required this.name,
    required this.firstHit,
    required this.isPrefix,
  });

  /// 在 [filterSkillNames] 入参里的下标（同分兜底用）。
  final int index;
  final String name;

  /// 首个命中字符在名字里的下标（贪心按序匹配的起点）。
  final int firstHit;

  /// 名字是否以查询串开头（不区分大小写）。
  final bool isPrefix;
}

/// 贪心按序子序列匹配：命中返回**首个命中字符**的下标，未命中返回 null。
///
/// 贪心从 0 开始扫，所以它给出的"首个命中字符下标"就是该名字能取到的最早起点 ——
/// 直接当排序键用。`needle` 必须非空（调用方 `filterSkillNames` 已保证）。
int? _subsequenceFirstHit(String needle, String haystack) {
  var matched = 0;
  var firstHit = -1;
  for (var i = 0; i < haystack.length; i++) {
    if (haystack.codeUnitAt(i) != needle.codeUnitAt(matched)) continue;
    if (firstHit < 0) firstHit = i;
    matched++;
    if (matched == needle.length) return firstHit;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 候选面板（任务 3.1）
// ---------------------------------------------------------------------------

/// 面板根节点的 key。
///
/// 用例靠它断"面板在/不在"（比断某一行文本更直接：空态行与候选行是两套文案）。
/// 只此一处定义，接缝不漏。
const Key kSlashCompletionPanelKey =
    ValueKey<String>('slash-completion-panel');

/// 候选面板的外观：候选行 / 高亮行 / 空目录提示 / 无命中提示。
///
/// 只负责画。**该不该显示、有几条、哪条高亮全由 `_InputBarState` 决定** ——
/// 状态的唯一持有者在那里（design D1/D2），本组件不持状态、不读技能目录。
///
/// 面板 **never request focus**（design D1 的硬规则）：行虽然是 `InkWell`，但显式
/// `canRequestFocus: false`，点它不把焦点从输入框抢走 —— 一旦抢走，失焦即关的
/// 规则会立刻把面板拆掉，点击就成了"先关面板再说"。
class SlashCompletionPanel extends StatelessWidget {
  const SlashCompletionPanel({
    super.key,
    required this.candidates,
    required this.highlightIndex,
    required this.emptyCatalog,
    required this.onAccept,
  });

  /// 当前候选（已由 [filterSkillNames] 排好序）。
  final List<String> candidates;

  /// 高亮行下标（[candidates] 非空时才有效）。
  final int highlightIndex;

  /// `true` = 生效技能集合为空（空目录空态文案）；
  /// `false` = 有技能但查询无命中（"无匹配技能"）。
  final bool emptyCatalog;

  /// 接受某一行时把下标交回状态机（键盘与鼠标走同一条路）。
  final ValueChanged<int> onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: kSlashCompletionPanelKey,
      elevation: 8,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: candidates.isEmpty
          ? _buildHint(theme)
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < candidates.length; i++) _buildRow(theme, i),
              ],
            ),
    );
  }

  /// 一行提示。空目录与"有技能但无命中"共用同一套中性信息色（不装成报错），
  /// 文案各自钉死（spec 的两条精确串）。
  Widget _buildHint(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Text(
        emptyCatalog
            ? kSlashCompletionEmptyCatalogHint
            : kSlashCompletionNoMatchHint,
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
    );
  }

  /// 一行候选：高亮行用 `secondaryContainer` 级色调（design D5：不新增品牌色）。
  Widget _buildRow(ThemeData theme, int index) {
    final highlighted = index == highlightIndex;
    return InkWell(
      canRequestFocus: false,
      onTap: () => onAccept(index),
      child: Ink(
        color: highlighted ? theme.colorScheme.secondaryContainer : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            candidates[index],
            style: theme.textTheme.bodyMedium?.copyWith(
              color: highlighted
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

/// 把面板摆进 Overlay（任务 3.1；design D5）。
///
/// 摆法：
///   - `CompositedTransformFollower` 贴住输入框的 `CompositedTransformTarget`；
///     `targetAnchor: topLeft` + `followerAnchor: bottomLeft` ⇒ 面板**底边**对齐
///     输入框**顶边**，再上移 [kSlashCompletionGap]。窗口缩放 / 页面滚动时由
///     compositing 层跟着走，不脱节。
///   - 外面套 `Align(topLeft)`：follower 的锚点按它**自己**的尺寸算，所以它必须只占
///     面板大小；`Align` 自己铺满浮层并把松约束给 follower。面板之外的点击照样
///     落到下面的界面（浮层不挡别处、也不占布局）。
///   - 宽度对齐输入框（调用方传入实测宽度）；高度上限 = 输入框上方实测可用空间，
///     技能很多时面板内部滚动，而不是长出屏幕。上限来自实测布局，不是发明的数字。
Widget buildSlashCompletionOverlay({
  required LayerLink link,
  required double width,
  required double maxHeight,
  required List<String> candidates,
  required int highlightIndex,
  required bool emptyCatalog,
  required ValueChanged<int> onAccept,
}) {
  final heightLimit = maxHeight > 0 ? maxHeight : 0.0;
  return Align(
    alignment: Alignment.topLeft,
    child: CompositedTransformFollower(
      link: link,
      showWhenUnlinked: false,
      targetAnchor: Alignment.topLeft,
      followerAnchor: Alignment.bottomLeft,
      offset: const Offset(0, -kSlashCompletionGap),
      child: SizedBox(
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: heightLimit),
          child: SingleChildScrollView(
            child: SlashCompletionPanel(
              candidates: candidates,
              highlightIndex: highlightIndex,
              emptyCatalog: emptyCatalog,
              onAccept: onAccept,
            ),
          ),
        ),
      ),
    ),
  );
}
