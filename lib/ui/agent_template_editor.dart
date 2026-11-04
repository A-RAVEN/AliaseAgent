import 'package:flutter/material.dart';

import '../models/agent_type_config.dart';
import '../models/model_catalog_entry.dart';
import '../services/agent_config_resolver.dart';
import '../services/agent_template_controller.dart';

/// 单个 Agent 模板的添加 / 修改编辑器（change `add-agent-object-and-templates`
/// 任务 3.2；change `add-provider-model-discovery` 任务 6.1–6.3）。
///
/// 字段：模板名（**只在添加时填写**，修改时只读）、provider、模型、推理强度、
/// 系统提示词、工具集合、输入模态与上下文窗口。模型字段是"目录下拉 + 自由输入"
/// 双通道：目录只提供默认值，手输目录外的模型也能保存（目录可能陈旧）。
class AgentTemplateEditor extends StatefulWidget {
  /// null = 添加；非空 = 修改该模板（名字只读）。
  final AgentTypeConfig? original;

  /// 可选 provider 名（来自 `AppConfig.providers`，不含密钥）。
  final List<String> providers;

  /// 每个 provider 的模型目录（来自 `providers.<名>.models`）。
  /// 没有目录的 provider 不在 map 里，模型字段照旧手填。
  final Map<String, List<ModelCatalogEntry>> catalogs;

  /// 可选工具名（来自 `ToolCatalog`）。
  final List<String> availableTools;

  /// 保存回调：把草稿交给 `AgentTemplateController`。抛
  /// [AgentTemplateValidationException] 时编辑器显示错误并保留输入。
  final Future<void> Function(AgentTemplateDraft draft) onSave;

  final VoidCallback? onCancel;

  const AgentTemplateEditor({
    super.key,
    this.original,
    required this.providers,
    this.catalogs = const {},
    required this.availableTools,
    required this.onSave,
    this.onCancel,
  });

  @override
  State<AgentTemplateEditor> createState() => AgentTemplateEditorState();
}

class AgentTemplateEditorState extends State<AgentTemplateEditor> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _modelCtrl;
  late final TextEditingController _promptCtrl;
  late final TextEditingController _windowCtrl;
  late String _provider;
  late String _effort;
  late Set<String> _tools;
  late Set<String> _modalities;

  String? _error;
  String? _errorField;
  bool _saving = false;

  /// 目录回填的提示与"被略去"的记录（可见，不静默）。
  String? _windowHint;
  List<String> _omittedModalities = const [];
  List<String> _unsupportedEfforts = const [];

  /// 已经为哪个模型 id 回填过：避免用户手输时每个字符都重填一遍，也避免打开
  /// 既有模板时把用户保存的窗口悄悄改掉（回填只在"用户选中模型"这个动作上发生）。
  String? _backfilledModelId;

  /// 模型改过之后，必须当场确认窗口（design 决策 1）。
  bool _windowConfirmedForModel = false;

  bool get isNew => widget.original == null;

  List<ModelCatalogEntry> get _catalog =>
      widget.catalogs[_provider] ?? const <ModelCatalogEntry>[];

  ModelCatalogEntry? get _selectedEntry {
    final text = _modelCtrl.text.trim();
    if (text.isEmpty) return null;
    for (final entry in _catalog) {
      if (entry.id == text) return entry;
    }
    return null;
  }

  /// 推理强度选项：目录已知时 = 目录档位 ∩ 执行层合法集合（`none` → 空串"关闭"）；
  /// 目录未知时保留全部合法集合供手选。
  List<String> get _effortOptions {
    final entry = _selectedEntry;
    final efforts = entry?.reasoningEfforts;
    if (efforts == null) {
      return [for (final e in AgentConfigResolver.kThinkingEfforts) e];
    }
    return [
      for (final e in AgentConfigResolver.kThinkingEfforts)
        if (efforts.contains(e)) e,
    ];
  }

  @override
  void initState() {
    super.initState();
    final o = widget.original;
    _nameCtrl = TextEditingController(text: o?.name ?? '');
    _modelCtrl = TextEditingController(text: o?.model ?? '');
    _promptCtrl = TextEditingController(text: o?.systemPrompt ?? '');
    _windowCtrl = TextEditingController(
        text: o?.maxContextTokens?.toString() ?? '');
    _provider = o?.provider ??
        (widget.providers.isNotEmpty ? widget.providers.first : '');
    _effort = o?.thinkingEffort ?? '';
    _modalities = {...(o?.inputModalities ?? AgentTypeConfig.kDefaultInputModalities)};
    // 添加时默认勾上目录里当前可用的全部工具（用户再按需取消）；修改时保留原清单。
    _tools = o != null ? {...o.tools} : {...widget.availableTools};
    _backfilledModelId = o?.model;
    _modelCtrl.addListener(_onModelChanged);
  }

  void _onModelChanged() {
    final originalModel = widget.original?.model ?? '';
    if (_modelCtrl.text.trim() == originalModel.trim()) {
      _windowConfirmedForModel = false;
    }
    _maybeBackfill(_modelCtrl.text);
  }

  /// 用户选中（或手输命中）目录里的模型时，以目录值为默认值回填三个输入框；
  /// 回填只发生在编辑器动作时，不参与运行时推导。
  void _maybeBackfill(String rawModel) {
    final model = rawModel.trim();
    final entry = _entryFor(model);
    if (entry == null) {
      if (mounted) {
        setState(() {
          _windowHint = null;
          _omittedModalities = const [];
          _unsupportedEfforts = const [];
        });
      }
      return;
    }
    if (_backfilledModelId == entry.id) return;
    _backfilledModelId = entry.id;

    if (entry.contextWindow != null) {
      _windowCtrl.text = entry.contextWindow!.toString();
      _windowHint = null;
    } else {
      _windowCtrl.text = '';
      _windowHint = '目录未提供窗口，请手填（压缩阈值依赖它）';
    }

    final allowed = AgentTypeConfig.kAllowedInputModalities;
    final kept = <String>[
      for (final m in entry.inputModalities)
        if (allowed.contains(m)) m,
    ];
    final omitted = <String>[
      for (final m in entry.inputModalities)
        if (!allowed.contains(m)) m,
    ];
    if (kept.isEmpty) {
      _modalities = {AgentTypeConfig.kDefaultInputModalities.first};
    } else {
      _modalities = kept.toSet();
    }
    _omittedModalities = omitted;
    if (omitted.isNotEmpty) {
      debugPrint('[AliasAgent] 目录模态 ${entry.id} 含产品发不出的取值 $omitted：'
          '回填模板时只保留 ${allowed.join("/")}，目录原值仍保留在 config.json 的目录里');
    }

    final unsupported = <String>[
      for (final e in entry.reasoningEfforts ?? const <String>[])
        if (e != 'none' && !AgentConfigResolver.kThinkingEfforts.contains(e)) e,
    ];
    _unsupportedEfforts = unsupported;
    final options = _effortOptions;
    if (_effort.isNotEmpty && !options.contains(_effort)) {
      _effort = '';
    }
    if (mounted) setState(() {});
  }

  ModelCatalogEntry? _entryFor(String model) {
    for (final entry in _catalog) {
      if (entry.id == model) return entry;
    }
    return null;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _modelCtrl.dispose();
    _promptCtrl.dispose();
    _windowCtrl.dispose();
    super.dispose();
  }

  AgentTemplateDraft _draft() => AgentTemplateDraft(
        originalName: widget.original?.name,
        name: _nameCtrl.text,
        provider: _provider,
        model: _modelCtrl.text,
        thinkingEffort: _effort,
        systemPrompt: _promptCtrl.text,
        tools: _tools.toList(),
        maxContextTokensText: _windowCtrl.text,
        inputModalities: _modalities.toList(),
      );

  Future<void> _submit() async {
    setState(() {
      _error = null;
      _errorField = null;
    });
    // 先在本地把"模型改了但没确认窗口"这条拦住：这是编辑器独有的要求。
    // 只有**修改既有模板**时才有"上一个模型的窗口"这个问题；添加时窗口必须
    // 由用户自己填（controller 会校验它是不是正整数）。
    if (!_windowConfirmedForModel &&
        widget.original != null &&
        AgentConfigResolver.windowConfirmationRequired(
          previousModel: widget.original?.model ?? '',
          nextModel: _modelCtrl.text,
        )) {
      final confirmed = await _confirmWindow();
      if (!confirmed) return;
      _windowConfirmedForModel = true;
    }

    setState(() => _saving = true);
    try {
      await widget.onSave(_draft());
    } on AgentTemplateValidationException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _errorField = e.field;
        _saving = false;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _saving = false;
      });
      return;
    }
    if (mounted) setState(() => _saving = false);
  }

  /// 模型变了 ⇒ 让用户当场确认新模型适用的窗口值（取消则不保存）。
  Future<bool> _confirmWindow() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认上下文窗口'),
        content: Text('模型已改为「${_modelCtrl.text.trim()}」。\n'
            '请确认上下文窗口 ${_windowCtrl.text.trim()} 适用于这个模型'
            '（窗口必须是正整数）。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-window'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entry = _selectedEntry;
    final catalogEmpty = _catalog.isEmpty;
    final modelNotInCatalog = !catalogEmpty &&
        _modelCtrl.text.trim().isNotEmpty &&
        entry == null;
    final canSave = widget.providers.isNotEmpty && !_saving;
    return AlertDialog(
      title: Text(isNew ? '添加 Agent 模板' : '修改 Agent 模板'),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.providers.isEmpty)
                Container(
                  key: const ValueKey('template-editor-no-providers'),
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  color: theme.colorScheme.tertiaryContainer,
                  child: Text(
                    '请先在 Providers 页添加供应商',
                    style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onTertiaryContainer),
                  ),
                ),
              if (_error != null)
                Container(
                  key: const ValueKey('template-editor-error'),
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  color: theme.colorScheme.errorContainer,
                  child: Text(
                    '${_errorField == null ? "" : "$_errorField："}$_error',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              TextField(
                key: const ValueKey('template-name'),
                controller: _nameCtrl,
                readOnly: !isNew,
                enabled: !_saving,
                decoration: InputDecoration(
                  labelText: '模板名',
                  helperText: isNew ? '创建后不可修改' : '模板名创建后不可修改（只读）',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey('template-provider'),
                initialValue: widget.providers.contains(_provider)
                    ? _provider
                    : null,
                decoration: const InputDecoration(
                  labelText: 'provider',
                  border: OutlineInputBorder(),
                ),
                items: [
                  for (final p in widget.providers)
                    DropdownMenuItem(value: p, child: Text(p)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                          _provider = value ?? '';
                          _windowHint = null;
                          _omittedModalities = const [];
                          _unsupportedEfforts = const [];
                          _backfilledModelId = null;
                        }),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      key: const ValueKey('template-model'),
                      controller: _modelCtrl,
                      enabled: !_saving,
                      decoration: InputDecoration(
                        labelText: '模型',
                        helperText: catalogEmpty
                            ? '该 Provider 没有目录，直接手填模型名'
                            : (modelNotInCatalog ? '不在最近一次目录中' : '可从右侧目录选择，也可手填'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 240,
                    child: DropdownButtonFormField<String>(
                      key: const ValueKey('template-model-picker'),
                      initialValue: entry?.id,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '目录',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final e in _catalog)
                          DropdownMenuItem(
                            value: e.id,
                            child: Text(e.displayName ?? e.id,
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      onChanged: _saving || catalogEmpty
                          ? null
                          : (value) {
                              if (value == null) return;
                              _modelCtrl.text = value;
                              _maybeBackfill(value);
                            },
                    ),
                  ),
                ],
              ),
              if (entry != null && entry.contextWindow == null) ...[
                const SizedBox(height: 4),
                Text(
                  '目录未提供窗口，请手填（压缩阈值依赖它）',
                  key: const ValueKey('template-window-hint'),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.tertiary),
                ),
              ],
              if (entry != null && entry.nativeEndpoints != null) ...[
                const SizedBox(height: 4),
                Text(
                  '目录标注原生直通：${entry.nativeEndpoints!.join("、")}'
                  '（仅参考，不作为可用性门禁）',
                  key: const ValueKey('template-native-endpoints'),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              if (entry != null && entry.pricing != null) ...[
                const SizedBox(height: 4),
                Text(
                  '目录计费：${entry.pricing}',
                  key: const ValueKey('template-pricing'),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: ValueKey(
                    'template-effort-${_effortOptions.join("-")}'),
                initialValue:
                    _effortOptions.contains(_effort) ? _effort : '',
                decoration: const InputDecoration(
                  labelText: '推理强度',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('关闭')),
                  for (final effort in _effortOptions)
                    DropdownMenuItem(value: effort, child: Text(effort)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _effort = value ?? ''),
              ),
              if (_unsupportedEfforts.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '目录档位 ${_unsupportedEfforts.join("、")} 暂不被执行层支持，未列入',
                  key: const ValueKey('template-unsupported-efforts'),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.tertiary),
                ),
              ],
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('template-system-prompt'),
                controller: _promptCtrl,
                enabled: !_saving,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '系统提示词',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('template-window'),
                controller: _windowCtrl,
                enabled: !_saving,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: false),
                decoration: InputDecoration(
                  labelText: '上下文窗口',
                  helperText: _windowHint ?? '正整数（token 数）',
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Text('输入模态', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: -8,
                children: [
                  for (final modality in AgentTypeConfig.kAllowedInputModalities.toList())
                    FilterChip(
                      key: ValueKey('modality-chip-$modality'),
                      label: Text(modality),
                      selected: _modalities.contains(modality),
                      onSelected: _saving
                          ? null
                          : (selected) => setState(() {
                                if (selected) {
                                  _modalities.add(modality);
                                } else if (_modalities.length > 1) {
                                  _modalities.remove(modality);
                                }
                              }),
                    ),
                ],
              ),
              if (_omittedModalities.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '目录里的 ${_omittedModalities.join("、")} 不在产品可发送范围，未加入',
                  key: const ValueKey('template-omitted-modalities'),
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
              const SizedBox(height: 12),
              Text('工具集合', style: theme.textTheme.labelLarge),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: -8,
                children: [
                  for (final tool in widget.availableTools)
                    FilterChip(
                      key: ValueKey('tool-chip-$tool'),
                      label: Text(tool),
                      selected: _tools.contains(tool),
                      onSelected: _saving
                          ? null
                          : (selected) => setState(() {
                                if (selected) {
                                  _tools.add(tool);
                                } else {
                                  _tools.remove(tool);
                                }
                              }),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (widget.onCancel != null)
          TextButton(onPressed: _saving ? null : widget.onCancel, child: const Text('取消')),
        FilledButton(
          key: const ValueKey('save-template'),
          onPressed: canSave ? _submit : null,
          child: _saving
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('保存'),
        ),
      ],
    );
  }
}
