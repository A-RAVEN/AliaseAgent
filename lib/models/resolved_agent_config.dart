/// 一个 Agent 实例创建时**冻结**的生效配置。
///
/// 它不是模板的另一份拷贝：模板（`AgentTypeConfig`）是用户可反复修改的**可复用定义**，
/// 而这里是"这一次创建到底用了什么"的只读快照。运行中的 Agent 只读这里，不再回头读
/// `agent_types.<名字>`，所以模板后续被改小窗口 / 换模型都不会热更新到已运行实例。
///
/// **provider 密钥与地址不进这里**：它们不是"行为配置"，而是创建时单独取得的执行依赖。
/// 这个类的 `toJson()` 因此可以被安全地写日志、塞进上下文快照或显示在界面上。
class ResolvedAgentConfig {
  /// 来源模板名。错误消息必须带上它（用户要知道是哪个模板坏了）。
  final String templateName;

  /// provider 的**名字**（引用键），不是密钥。
  final String providerName;

  final String model;

  /// `adaptive` 或 `disabled`。由 `thinkingEffort` 推导，见
  /// `AgentConfigResolver.thinkingModeFor`。
  final String thinkingMode;

  /// 生效的推理强度；[thinkingMode] 为 `disabled` 时是空串。
  final String thinkingEffort;

  final String systemPrompt;

  /// 本实例允许发给模型的工具名（尚未按目录过滤；过滤与校验见 Agent 创建路径）。
  final List<String> tools;

  /// 模型上下文窗口。创建时已校验为正整数。
  final int maxContextTokens;

  /// 压缩阈值百分比（窗口 × 该值 ÷ 100 得到阈值 token 数）。
  final int compactionThresholdPercent;

  /// 等待压缩的占比上界百分比（窗口 × 该值 ÷ 100）。
  final int compactionWaitThresholdPercent;

  /// 这个模型能吃哪些输入模态（`text` / `image`）。
  final List<String> inputModalities;

  /// 命令工具的缺省超时与超时上限毫秒数。
  final int commandTimeoutMs;
  final int commandMaxTimeoutMs;

  /// 压缩时**不可折叠**的显式要求（guard anchors）。
  final List<String> standingRequirements;

  /// 工具输出 spill 的头尾预览字符数（顶层 `spill.preview_chars`）。
  ///
  /// 命令工具与 `read_spill` 每次调用都要把它随请求传给执行侧，所以它属于实例生效
  /// 配置；它不在模板里，而是来自顶层配置块。
  final int spillPreviewChars;

  const ResolvedAgentConfig({
    required this.templateName,
    required this.providerName,
    required this.model,
    required this.thinkingMode,
    required this.thinkingEffort,
    required this.systemPrompt,
    required this.tools,
    required this.maxContextTokens,
    required this.compactionThresholdPercent,
    required this.compactionWaitThresholdPercent,
    required this.inputModalities,
    required this.commandTimeoutMs,
    required this.commandMaxTimeoutMs,
    required this.standingRequirements,
    required this.spillPreviewChars,
  });

  /// 这个实例能不能接收图片输入。
  bool get acceptsImages => inputModalities.contains('image');

  /// 只改系统提示词 / 工具清单的派生副本（一次性子 Agent 用）。
  ///
  /// 共享的参数值全部原样带过来；调用方拿到的是新对象，父实例与模板都不受影响。
  ResolvedAgentConfig copyWith({
    String? systemPrompt,
    List<String>? tools,
  }) =>
      ResolvedAgentConfig(
        templateName: templateName,
        providerName: providerName,
        model: model,
        thinkingMode: thinkingMode,
        thinkingEffort: thinkingEffort,
        systemPrompt: systemPrompt ?? this.systemPrompt,
        tools: tools ?? this.tools,
        maxContextTokens: maxContextTokens,
        compactionThresholdPercent: compactionThresholdPercent,
        compactionWaitThresholdPercent: compactionWaitThresholdPercent,
        inputModalities: inputModalities,
        commandTimeoutMs: commandTimeoutMs,
        commandMaxTimeoutMs: commandMaxTimeoutMs,
        standingRequirements: standingRequirements,
        spillPreviewChars: spillPreviewChars,
      );

  /// 压缩阈值 token 数：上下文窗口 × 百分比 ÷ 100。
  ///
  /// 这是**推导值**，不是配置值 —— 用户钉死了"只允许由窗口乘百分比算出的 token
  /// 阈值"（`TODO.md` 顶部那条），所以这里不写任何绝对 token 数。
  int get compactionThresholdTokens =>
      maxContextTokens * compactionThresholdPercent ~/ 100;

  /// 可序列化快照：**不含** `api_key` / `base_url`。
  Map<String, dynamic> toJson() => {
        'template': templateName,
        'provider': providerName,
        'model': model,
        'thinking_mode': thinkingMode,
        'thinking_effort': thinkingEffort,
        'system_prompt': systemPrompt,
        'tools': List<String>.unmodifiable(tools),
        'max_context_tokens': maxContextTokens,
        'compaction_threshold_percent': compactionThresholdPercent,
        'compaction_wait_threshold_percent': compactionWaitThresholdPercent,
        'input_modalities': List<String>.unmodifiable(inputModalities),
        'command_timeout_ms': commandTimeoutMs,
        'command_max_timeout_ms': commandMaxTimeoutMs,
        'standing_requirements': List<String>.unmodifiable(standingRequirements),
        'spill_preview_chars': spillPreviewChars,
      };

  @override
  String toString() => 'ResolvedAgentConfig(template=$templateName, '
      'provider=$providerName, model=$model, '
      'window=$maxContextTokens, tools=${tools.join(",")})';
}
