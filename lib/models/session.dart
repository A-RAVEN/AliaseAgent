import '../models/instance_overrides.dart';

/// 组的**反应轮数上限**产品默认值（change `group-reactive-mode` R.1 / design D13）。
///
/// 依据（design D13）：典型 3 人群聊的 2–3 个来回约 4–6 个反应轮，再加 2 轮评价/回应
/// 余量；不取 3（用户示例 3 层会把正常讨论截断），不取几十（默认就失去保险意义）。
/// 它是**代码常量**，不是 `config.json` 键；`sessions.max_reaction_rounds` 为 NULL 时用它。
const int kDefaultMaxReactionRounds = 8;

/// 上限的合法下界（design D13：范围 1..50；0 / 负数被拒绝，不静默截断）。
const int kMinMaxReactionRounds = 1;

/// 上限的合法上界（design D13）。
const int kMaxMaxReactionRounds = 50;

/// 上限是不是一个可接受的显式值（组设置的唯一判据；`null` = 用默认，也合法）。
bool isValidMaxReactionRounds(int? value) =>
    value == null || (value >= kMinMaxReactionRounds && value <= kMaxMaxReactionRounds);

class Session {
  /// 单 Agent 会话（缺省；变更前的所有会话都是它）。
  static const String kindSingle = 'single';

  /// 组会话：成员共享一份原文，单 Agent 入口一律拒绝（`agent-group-chat` D16）。
  static const String kindGroup = 'group';

  static const Set<String> kKindValues = {kindSingle, kindGroup};

  final String id;
  final String title;
  final String agentType;

  /// 会话种类（config 里没有这一项：它是数据库列，见 `session-persistence`）。
  ///
  /// 旧行 / 旧创建路径没有这一列 ⇒ 读成 `single`；非法值同样回落 `single`
  /// （一条手改出来的 `kind` 不该把会话凭空变成组）。
  final String kind;

  /// 单 Agent 会话的覆盖层（`sessions.overrides_json`，可空）。
  ///
  /// 与成员行的 `overrides_json` 走**同一个解析器**（`AgentInstanceOverrides`）。
  final String? overridesJson;

  /// 父会话 id：普通顶层会话为 `null`；一次性子 Agent 的运行记录指向父会话。
  /// 普通列表只返回该字段为 `null` 的顶层会话（见 `SessionRepository.list`）。
  final String? parentSessionId;
  final int createdAt;
  final int updatedAt;

  /// 组的**自发反应开关**（`sessions.reactions_enabled`，change
  /// `group-reactive-mode` D1 / D8）。它是组的持久属性，不是 `config.json` 键。
  ///
  /// 三处口径（design D8 第 5 条）：
  ///   - 构造函数缺省 `true`（**新建组默认开启**；点名不该是默认体验）；
  ///   - `toRow` 写成 1/0；
  ///   - `fromRow` 在**列缺失或为 null** 时按 `false` 解释（未迁移的旧库 / 手工夹具
  ///     = 旧点名行为），列存在时按值解释。
  ///
  /// 单会话行也带这一列，但它不影响单 Agent 的任何行为（`group_reactive` 只读组行）。
  final bool reactionsEnabled;

  /// 组的**反应轮数上限**（`sessions.max_reaction_rounds`，可空；change
  /// `group-reactive-mode` R.1 / design D13）。
  ///
  /// `null` = 用产品默认 [kDefaultMaxReactionRounds]（组设置，**不是** `config.json` 键）。
  /// 范围 [kMinMaxReactionRounds]..[kMaxMaxReactionRounds]：越界由 `group.update` 拒绝
  /// （`-32602`），不静默截断。单会话行也带该列，但值不影响单 Agent 行为。
  final int? maxRounds;

  /// 会话 / 组的**工作路径设置值**（`sessions.workspace`，可空；change
  /// `custom-workspace` design D2 / D4）。
  ///
  /// `null` = **未设置**：恢复时沿用产品既有缺省 `ConfigService.homeDir`（本 change
  /// 不改缺省口径），库里的 NULL 不会被回填成主目录。组会话的该列就是组的**共享**
  /// 工作区（成员继承，没有私有工作区）。
  ///
  /// 存的是「设置值」（规范化后的用户输入，保留其分隔符风格）；上下文里的是 sidecar
  /// 规范化后的「生效值」。两者指向同一目录，比较用 `p.equals`。
  final String? workspace;

  const Session({
    required this.id,
    required this.title,
    this.agentType = 'general',
    this.parentSessionId,
    required this.createdAt,
    required this.updatedAt,
    this.kind = kindSingle,
    this.overridesJson,
    this.reactionsEnabled = true,
    this.maxRounds,
    this.workspace,
  }) : assert(
          kind == kindSingle || kind == kindGroup,
          'kind 只能是 single 或 group：收到 "$kind"',
        );

  /// 是不是组会话。
  bool get isGroup => kind == kindGroup;

  /// 会话级覆盖层；null = 没有覆盖（列缺失 / 坏 JSON 都按无覆盖处理）。
  AgentInstanceOverrides? get overrides => AgentInstanceOverrides.parse(overridesJson);

  factory Session.fromRow(Map<String, dynamic> row) {
    final rawKind = row['kind'] as String?;
    // `containsKey == false`（旧库缺列）与显式 null 都按 false 解释：那是「旧点名
    // 行为」，不是新默认 true（design D8 第 5 条）。
    final rawReactions = row['reactions_enabled'];
    final reactionsEnabled = rawReactions is int && rawReactions != 0;
    // 上限：缺列 / null 都读成 null（= 用产品默认，design D13）。
    final rawMaxRounds = row['max_reaction_rounds'];
    final maxRounds = rawMaxRounds is int ? rawMaxRounds : null;
    return Session(
      id: row['id'] as String,
      title: row['title'] as String,
      agentType: row['agent_type'] as String? ?? 'general',
      parentSessionId: row['parent_session_id'] as String?,
      createdAt: row['created_at'] as int,
      updatedAt: row['updated_at'] as int,
      kind: kKindValues.contains(rawKind) ? rawKind! : kindSingle,
      overridesJson: row['overrides_json'] as String?,
      reactionsEnabled: reactionsEnabled,
      maxRounds: maxRounds,
      // 缺列（旧库 / 手工夹具）与显式 NULL 都读成 null：语义是「未设置、用缺省」。
      workspace: row['workspace'] as String?,
    );
  }

  Map<String, dynamic> toRow() => {
        'id': id,
        'title': title,
        'agent_type': agentType,
        'parent_session_id': parentSessionId,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'kind': kind,
        'overrides_json': overridesJson,
        'reactions_enabled': reactionsEnabled ? 1 : 0,
        'max_reaction_rounds': maxRounds,
        'workspace': workspace,
      };

  Session copyWith({
    String? title,
    String? agentType,
    int? updatedAt,
    String? overridesJson,
    bool clearOverrides = false,
    bool? reactionsEnabled,
    int? maxRounds,
    bool clearMaxRounds = false,
    String? workspace,
    bool clearWorkspace = false,
  }) {
    return Session(
      id: id,
      title: title ?? this.title,
      agentType: agentType ?? this.agentType,
      parentSessionId: parentSessionId,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      kind: kind,
      overridesJson:
          clearOverrides ? null : (overridesJson ?? this.overridesJson),
      reactionsEnabled: reactionsEnabled ?? this.reactionsEnabled,
      // `maxRounds: null` 与「不传」在命名参数上不可区分（同 `clearOverrides`
      // 的先例）：要恢复默认显式传 `clearMaxRounds: true`。
      maxRounds: clearMaxRounds ? null : (maxRounds ?? this.maxRounds),
      // workspace 同理：`null` 与「不传」不可区分，清空要显式传 `clearWorkspace: true`。
      workspace: clearWorkspace ? null : (workspace ?? this.workspace),
    );
  }
}
