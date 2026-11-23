// 自发反应（reactive group chat）的**纯原语**：结构化 PASS 终态工具、`@显示名` 解析、
// 反应轮规划、steps 的封闭枚举（change `group-reactive-mode` R.10 / design D3、D5、D9）。
//
// 这一层刻意不碰 DB、不碰 sidecar、不碰 Agent：全部是纯函数与常量，所以
//   - 单测能逐条钉住判定与顺序（不需要真库、不需要假 sidecar）；
//   - 调度器（`group_service.dart`）只负责"什么时候调用它、拿结果去跑谁"，
//     判定口径不会散落在调度代码里。

import '../models/group_member.dart';

/// 旧的文本沉默哨兵（**R.10 起不再参与判定**）。
///
/// 历史：模型被要求在正文里整条只写 `[PASS]` 表示沉默；用户实测模型不遵守
/// （会写「我这回合不发言」之类元话术），于是 R.10 改成结构化终态工具
/// [kGroupReactToolName]。本常量只保留给用户文档说明「普通轮里的 `[PASS]` 是普通
/// 正文」与迁移对照，**MUST NOT** 再用它判定反应轮是否沉默。
const String kGroupPassSentinel = '[PASS]';

/// 结构化 PASS 的终态控制工具名（R.10 / design D5）。
///
/// 它**不是** `ToolCatalog` 里的普通工具：只在该轮作为控制工具注入 tools JSON，
/// Agent 的模型循环拦截它并立即结束本轮（不执行、不写 tool 行）。
const String kGroupReactToolName = 'group_react';

/// 模型结束反应轮却没有调用 `group_react` 时的可归因错误。
const String kMissingGroupReactError = 'missing_group_react';

/// `group_react` 参数非法 / 同一轮多次调用时的可归因错误。
const String kInvalidGroupReactError = 'invalid_group_react';

/// 反应轮结构化调用不合规时的**纠正重试上限**（R.11）。
///
/// 依据：用户 2026-11-23 拍板「模型没调 group_react 时像工具失败那样回一条警告要求
/// 它重来」，并建议上限 2。一次纠正覆盖「漏调用」，第二次覆盖「先口头答应、下一轮
/// 才补调用」；再往上只是重复烧 token 而不增加信息。它是**产品常量**，不是配置键；
/// 计数按成员轮（一次 `Agent.send`）累计，超限才 failed。
const int kMaxGroupReactRetries = 2;

/// 缺失 / 非法调用后追加给模型的纠正消息（类比工具错误反馈）。
///
/// 用 user 轮文本回给模型，明确「本轮必须调用一次」「参数形状」「pass 两种含义」，
/// 并禁止用正文代替 / 写元话术。它**不写库**，只存在于本次模型循环的请求上下文里。
String groupReactCorrectionPrompt(String error) =>
    '你没有正确调用 group_react 工具（$error）。本轮必须调用 group_react 恰好一次，'
    '参数为 {"pass": boolean, "message": string}：pass=true 表示沉默（不写公开内容），'
    'pass=false 表示发言且 message 是唯一会公开的内容。请重新调用 group_react 表达'
    '本轮决定；不要用正文代替，也不要写「我 PASS」「我不发言」这类元话术。';

/// `group_react` 的工具定义（`input_schema {pass: boolean, message: string}`）。
///
/// `pass=true` 时 `message` 可空且被忽略；`pass=false` 时 `message` 是**唯一**公开内容。
/// 它不进工具目录、不进模板勾选清单、也不写 tool 行。
const Map<String, dynamic> kGroupReactToolDefinition = {
  'name': kGroupReactToolName,
  'description': '本轮终态控制工具：结束这一轮并声明是否发言。'
      'pass=true 表示本轮沉默（不写公开内容，message 被忽略）；'
      'pass=false 表示本轮发言，公开内容只取 message 字段。'
      '每轮必须恰好调用一次。',
  'input_schema': {
    'type': 'object',
    'properties': {
      'pass': {
        'type': 'boolean',
        'description': 'true = 本轮沉默（不说话）；false = 本轮发言。必填。',
      },
      'message': {
        'type': 'string',
        'description': 'pass=false 时唯一会公开的内容（自包含：结论 + 文件指针）；'
            'pass=true 时可空且被忽略。必填。',
      },
    },
    'required': ['pass', 'message'],
  },
};

/// `group_react` 的结构化判定结果（R.10 / design D5）。
///
/// 三态：沉默（[isPass]）/ 发言（[isSpeak]，`message` 可能是空串 ⇒ 上层记 empty）/
/// 失败（[isFailed]，带 `missing_group_react` / `invalid_group_react`）。
/// 失败**不写公开行**，也**不回退到** `[PASS]` 文本匹配。
class GroupReactDecision {
  const GroupReactDecision._({required this.kind, this.message, this.error});

  const GroupReactDecision.pass([String? message])
      : this._(kind: GroupReactDecision.passKind, message: message);

  const GroupReactDecision.speak(String message)
      : this._(kind: GroupReactDecision.speakKind, message: message);

  const GroupReactDecision.failure(String error)
      : this._(kind: GroupReactDecision.failureKind, error: error);

  static const String passKind = 'pass';
  static const String speakKind = 'speak';
  static const String failureKind = 'failure';

  final String kind;

  /// `isSpeak` 时是 `group_react.message`（可能为空串）；其它状态为 null。
  final String? message;

  /// `isFailed` 时的可归因错误码。
  final String? error;

  bool get isPass => kind == passKind;

  bool get isSpeak => kind == speakKind;

  bool get isFailed => kind == failureKind;
}

/// 解析本轮的 `group_react` 调用（Agent 拦截后把原始 `tool_use` 交给它）。
///
/// 口径（design D5）：
///   - 恰好一次调用、`input.pass` 是布尔；`pass=true` ⇒ [GroupReactDecision.pass]
///     （`message` 写什么都不看）；
///   - `pass=false` 且 `message` 是字符串 ⇒ [GroupReactDecision.speak]（可为空串）；
///   - 零次 ⇒ `missing_group_react`；多次 / 参数非法 ⇒ `invalid_group_react`。
GroupReactDecision parseGroupReactDecision(
    List<Map<String, dynamic>> calls) {
  if (calls.isEmpty) {
    return const GroupReactDecision.failure(kMissingGroupReactError);
  }
  if (calls.length != 1) {
    return const GroupReactDecision.failure(kInvalidGroupReactError);
  }
  final input = calls.single['input'];
  if (input is! Map) {
    return const GroupReactDecision.failure(kInvalidGroupReactError);
  }
  final pass = input['pass'];
  if (pass is! bool) {
    return const GroupReactDecision.failure(kInvalidGroupReactError);
  }
  if (pass) {
    // pass=true 的 message 不进入任何公开内容；仍带回 decision 供调用方观察
    // （`finalText` 保留它，测试与日志能看出模型想说什么）。
    final message = input['message'];
    return GroupReactDecision.pass(message is String ? message : null);
  }
  final message = input['message'];
  if (message is! String) {
    return const GroupReactDecision.failure(kInvalidGroupReactError);
  }
  return GroupReactDecision.speak(message);
}

/// 反应链 step 的来源（封闭枚举，RPC 契约；spec「群聊 RPC 面」/ design D9）。
///
///   - `speaker`：本次发送显式点名（开启态强制轮 / 关闭态普通轮）；
///   - `mention`：用户消息里 `@显示名` 命中的强制轮；
///   - `reaction`：开关开启时对公开消息的自愿反应轮。
const Set<String> kReactionStepSources = {'speaker', 'mention', 'reaction'};

/// 反应链 step 的状态（封闭枚举，RPC 契约）。
///
///   - `replied`：产生了公开行（`publicSeq` 非空）；
///   - `passed`：自愿轮整条输出恰为 `[PASS]`（不写公开行）；
///   - `forced_pass`：强制轮仍输出恰为 `[PASS]`（可归因失败，**不是**整轮失败）；
///   - `forced_empty`：强制轮输出为空 / 纯空白（可归因失败）；
///   - `empty`：自愿轮输出为空 / 纯空白（不写公开行）；
///   - `failed`：该成员轮硬失败（`AgentRunResult.isFailed`）；
///   - `cancelled`：该成员轮被取消。
const Set<String> kReactionStepStatuses = {
  'replied',
  'passed',
  'forced_pass',
  'forced_empty',
  'empty',
  'failed',
  'cancelled',
};

/// 链的生命周期状态（封闭枚举，`group.chain` 契约；change
/// `group-reactive-mode` R.2 / design D7 / D9）。
///
///   - `idle`：本进程内还没有链；
///   - `running`：链在后台跑（`stopReason` 为 null）；
///   - `completed`：正常终态（`stopReason ∈ {all_passed, round_cap, no_members}`）；
///   - `cancelled`：被 `agent.cancel` 或结构操作停掉；
///   - `failed`：成员轮硬失败 / 后台异常。
const Set<String> kGroupChainStatuses = {
  'idle',
  'running',
  'completed',
  'cancelled',
  'failed',
};

/// 链的结束原因（封闭枚举，`group.chain` 契约；change `group-reactive-mode`
/// R.2 / design D3 的 `stopReason` 映射）。
///
///   - `all_passed`：至少跑过一轮，最后一轮没有产生任何公开消息，且已无可反应成员；
///   - `round_cap`：还有可反应成员，但反应轮数已达该组上限（优雅停，不是报错）；
///   - `cancelled`：被取消；
///   - `failed`：硬失败 / 后台异常；
///   - `no_members`：规划不到可反应成员（首轮无人、末轮有回复但无人可接，
///     安静态定向轮集合跑完也归这里）。
const Set<String> kGroupChainStopReasons = {
  'all_passed',
  'round_cap',
  'cancelled',
  'failed',
  'no_members',
};

/// `@显示名` 后面允许出现的边界字符：空白与常见中英文标点。
///
/// 判据是「名字后面必须是字符串结尾 / 空白 / 标点」（spec「@ 点名定向响应」）：
/// 不加边界判断的话组里同时有「甲」与「甲二」时，`@甲二` 会被「甲」抢先匹配成
/// 一个错误的成员。最长名优先（见 [parseMentionedMemberIds]）解决同一位置的歧义，
/// 边界判断解决"名字只是更长名字的前缀"这一半。
const String _kMentionBoundaryPunctuation =
    '，。！？、；：,.!?;:\'"“”‘’()（）[]【】<>《》…—-';

bool _isMentionBoundary(String char) =>
    char.trim().isEmpty || _kMentionBoundaryPunctuation.contains(char);

/// 从一段用户文本里解析出被 `@` 点名的成员 id（按出现顺序去重）。
///
/// 口径（spec「@ 点名定向响应」/ design D3）：
///   - 只匹配**未移除**成员；
///   - 同一位置**最长名字优先**；
///   - 名字后面必须是结尾 / 空白 / 标点，否则不算命中；
///   - 多个命中按出现顺序去重；
///   - 未知 `@…` 原样留在正文里（本函数不修改文本，只报告命中）。
///
/// 只对**用户消息**调用：agent 公开回复里的 `@` 只是正文（design D4 末条）。
List<String> parseMentionedMemberIds(
  String text,
  List<GroupMember> members,
) {
  if (text.isEmpty) return const [];
  // 只保留未移除成员，并按名字长度倒序：同一位置先试最长名。
  final candidates = [
    for (final member in members)
      if (!member.isRemoved && member.name.isNotEmpty) member,
  ]..sort((a, b) {
      final byLength = b.name.length.compareTo(a.name.length);
      if (byLength != 0) return byLength;
      return a.name.compareTo(b.name);
    });
  final out = <String>[];
  var index = 0;
  while (index < text.length) {
    if (text[index] != '@') {
      index++;
      continue;
    }
    final start = index + 1;
    GroupMember? matched;
    for (final member in candidates) {
      final end = start + member.name.length;
      if (end > text.length) continue;
      if (text.substring(start, end) != member.name) continue;
      // 名字后面必须是结尾 / 空白 / 标点。
      if (end < text.length && !_isMentionBoundary(text[end])) continue;
      matched = member;
      break;
    }
    if (matched == null) {
      // 未知 @：不解析，也不吞掉后面的文本。
      index = start;
      continue;
    }
    if (!out.contains(matched.id)) out.add(matched.id);
    index = start + matched.name.length;
  }
  return out;
}

/// 一个可反应成员 + 它这一轮是不是被强制（`@mention` / speaker 强制轮）。
class ReactionTarget {
  const ReactionTarget({required this.member, required this.forced});

  final GroupMember member;

  /// true = 这一轮必须实质回应（被 `@` 点名，或开启态被 speaker 点名）。
  final bool forced;

  @override
  String toString() =>
      'ReactionTarget(${member.name}/${member.id}, forced=$forced)';
}

/// 规划一个反应轮：**谁该对 `triggerSeq` 这条公开消息反应，按什么顺序跑**。
///
/// 口径（design D3）：
///   - 仍在组里（`removed_at` 为空）；
///   - 不是该公开消息的作者（不自己反应自己）；
///   - `lastReactedSeq[member] < triggerSeq`（只对更新的公开消息反应）；
///   - [forcedMemberIds]（用户文本里的 `@` 点名，已按出现顺序）排最前、标记 forced；
///   - 其余按加入顺序（`createdAt`，同值保持入参顺序 —— 仓储按 `created_at, rowid`
///     读出，所以入参顺序即 rowid 兜底顺序）。
///
/// 返回值**空**是链的正常出口（全 PASS / 无人可反应），不是错误。
List<ReactionTarget> planReactionRound({
  required List<GroupMember> members,
  required int triggerSeq,
  required String? triggerAuthor,
  required Map<String, int> lastReactedSeq,
  List<String> forcedMemberIds = const [],
}) {
  final eligible = <GroupMember>[];
  for (final member in members) {
    if (member.isRemoved) continue;
    if (triggerAuthor != null && member.id == triggerAuthor) continue;
    final last = lastReactedSeq[member.id];
    if (last != null && last >= triggerSeq) continue;
    eligible.add(member);
  }
  if (eligible.isEmpty) return const [];

  final forcedIds = <String>[];
  for (final id in forcedMemberIds) {
    if (forcedIds.contains(id)) continue;
    if (!eligible.any((member) => member.id == id)) continue;
    forcedIds.add(id);
  }

  // 加入顺序：createdAt 升序，同值保持 eligible 的原始顺序（List.sort 在 Dart 里
  // 不保证稳定，所以自己做插入式排序 —— 顺序必须可复现，design D3）。
  final ordered = <GroupMember>[];
  for (final member in eligible) {
    var inserted = false;
    for (var i = 0; i < ordered.length; i++) {
      if (member.createdAt < ordered[i].createdAt) {
        ordered.insert(i, member);
        inserted = true;
        break;
      }
    }
    if (!inserted) ordered.add(member);
  }

  final out = <ReactionTarget>[];
  for (final id in forcedIds) {
    out.add(ReactionTarget(
      member: ordered.firstWhere((member) => member.id == id),
      forced: true,
    ));
  }
  for (final member in ordered) {
    if (forcedIds.contains(member.id)) continue;
    out.add(ReactionTarget(member: member, forced: false));
  }
  return out;
}
