/// 压缩进行中的状态：空闲，或"正在做哪个阶段、做到第几段"。
///
/// 界面用它显示"正在压缩"的提示（见 `lib/ui/compaction_status_banner.dart`）。
/// 它只说明**压缩这一件事正在做**，不代表"正在发送"：没触发压缩的普通发送
/// 不会产生非空闲状态（置位只发生在真正要发起压缩相关模型请求的地方，见
/// `lib/main.dart` 的 `_prepareSeamChooser` 与 `_resolveSummaries`）。
enum CompactionStage {
  /// 正在挑选分段主题（这一步自己要发一次模型请求）。
  seamSelection,

  /// 正在把较早的对话逐段生成一级摘要。
  level1,

  /// 正在把一级摘要合成为二级摘要。
  level2,
}

/// 一次压缩的可显示状态。[idle] 表示没有任何压缩在进行。
class CompactionStatus {
  /// 当前阶段；为 null 表示空闲。
  final CompactionStage? stage;

  /// 正在生成第几段（从 1 开始）。阶段本身不带分段时是 0。
  final int segment;

  /// 这一步一共要生成几段；事先不知道时为 null —— 那时只报"正在生成第几段"，
  /// 不编造分母。
  final int? total;

  /// 这次压缩是不是"你空闲时自动跑的后台压缩"。是的话提示要说明"发消息会让它
  /// 先让路"（发送前那次压缩不显示这句：那时用户本来就在等）。
  final bool background;

  const CompactionStatus._(this.stage, this.segment, this.total, this.background);

  /// 没有任何压缩在进行。
  static const CompactionStatus idle =
      CompactionStatus._(null, 0, null, false);

  bool get isIdle => stage == null;

  /// 正在挑选分段主题。
  factory CompactionStatus.seam({bool background = false}) =>
      CompactionStatus._(CompactionStage.seamSelection, 0, null, background);

  /// 正在生成第 [segment] 段一级摘要（[total] 已知就给"共几段"）。
  factory CompactionStatus.level1(
          {required int segment, int? total, bool background = false}) =>
      CompactionStatus._(CompactionStage.level1, segment, total, background);

  /// 正在把一级摘要合成第 [segment] 段二级摘要。
  factory CompactionStatus.level2(
          {required int segment, int? total, bool background = false}) =>
      CompactionStatus._(CompactionStage.level2, segment, total, background);

  /// 提示里显示的那句话；空闲时为 null（界面不渲染任何东西）。
  String? get label {
    switch (stage) {
      case null:
        return null;
      case CompactionStage.seamSelection:
        return '正在挑选分段主题';
      case CompactionStage.level1:
        return '正在压缩较早的对话：正在生成第 $segment 段摘要${_ofTotal()}';
      case CompactionStage.level2:
        return '正在把一级摘要合成二级摘要：正在生成第 $segment 段${_ofTotal()}';
    }
  }

  String _ofTotal() => total == null ? '' : '，共 $total 段';

  /// 后台压缩时补的一句；发送前那次压缩为 null。
  String? get note =>
      background ? '你发消息会让压缩先让路' : null;
}
