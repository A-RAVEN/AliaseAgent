import 'package:flutter/material.dart';

import '../models/agent_type_config.dart';
import '../services/agent_config_resolver.dart';
import '../services/agent_template_controller.dart';

/// 单个 Agent 模板的添加 / 修改编辑器（任务 3.2）。
///
/// 字段：模板名（**只在添加时填写**，修改时只读）、provider、模型、推理强度、
/// 系统提示词、工具集合与上下文窗口。保存前校验；校验失败时**保留用户输入**并
/// 指出具体字段。第一版没有删除按钮，也没有改名与实例覆盖入口。
class AgentTemplateEditor extends StatefulWidget {
  /// null = 添加；非空 = 修改该模板（名字只读）。
  final AgentTypeConfig? original;

  /// 可选 provider 名（来自 `AppConfig.providers`，不含密钥）。
  final List<String> providers;

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

  String? _error;
  String? _errorField;
  bool _saving = false;

  /// 模型改过之后，必须当场确认窗口（design 决策 1）。
  bool _windowConfirmedForModel = false;

  bool get isNew => widget.original == null;

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
    // 添加时默认勾上目录里当前可用的全部工具（用户再按需取消）；修改时保留原清单。
    _tools = o != null ? {...o.tools} : {...widget.availableTools};
    _modelCtrl.addListener(_onModelChanged);
  }

  void _onModelChanged() {
    final originalModel = widget.original?.model ?? '';
    if (_modelCtrl.text.trim() == originalModel.trim()) {
      _windowConfirmedForModel = false;
    }
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
    return AlertDialog(
      title: Text(isNew ? '添加 Agent 模板' : '修改 Agent 模板'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
                    : (value) => setState(() => _provider = value ?? ''),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('template-model'),
                controller: _modelCtrl,
                enabled: !_saving,
                decoration: const InputDecoration(
                  labelText: '模型',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                key: const ValueKey('template-effort'),
                initialValue: _effort,
                decoration: const InputDecoration(
                  labelText: '推理强度',
                  border: OutlineInputBorder(),
                ),
                items: [
                  const DropdownMenuItem(value: '', child: Text('关闭')),
                  for (final effort in AgentConfigResolver.kThinkingEfforts)
                    DropdownMenuItem(value: effort, child: Text(effort)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _effort = value ?? ''),
              ),
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
                decoration: const InputDecoration(
                  labelText: '上下文窗口',
                  helperText: '正整数（token 数）',
                  border: OutlineInputBorder(),
                ),
              ),
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
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('保存'),
        ),
      ],
    );
  }
}
