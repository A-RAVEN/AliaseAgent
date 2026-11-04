import 'package:flutter/material.dart';

import '../models/agent_type_config.dart';
import '../models/app_config.dart';
import '../models/provider_config.dart';
import '../services/config_service.dart';
import '../services/model_discovery_service.dart';

/// Provider 管理页（change `add-provider-model-discovery` 任务 4.1–4.3）。
///
/// 列表只显示名字、网关地址与目录状态，**不显示密钥明文**；编辑表单里密钥框
/// 是遮蔽输入，编辑既有 Provider 时留空表示"沿用原密钥"。
///
/// 删除前扫描 `agent_types` 的引用；被引用时拒绝并在该行显示引用模板名。
/// 改名在**同一保存动作**里改写所有引用旧名的模板 `provider` 字段，一次写盘。
class ProvidersPage extends StatefulWidget {
  /// 打开页面时的配置快照（之后以页面内的 `_config` 为准）。
  final AppConfig config;

  /// 探测动作；注入假实现供 widget 测试使用。null = 真实的 HTTP 探测。
  final ProviderCatalogDiscovery? discovery;

  /// 写回哪份配置；null = 产品默认的 `~/.aliasagent/config.json`。
  final String? configPath;

  /// 配置被改动后的回调（成功探测写回也会触发）。
  final ValueChanged<AppConfig>? onConfigChanged;

  const ProvidersPage({
    super.key,
    required this.config,
    this.discovery,
    this.configPath,
    this.onConfigChanged,
  });

  @override
  State<ProvidersPage> createState() => ProvidersPageState();
}

class ProvidersPageState extends State<ProvidersPage> {
  late AppConfig _config;
  late final ProviderCatalogDiscovery _discovery;

  /// 每个 Provider 最近一次探测结果（只在本次页面会话内保留；目录本身持久化）。
  final Map<String, ModelDiscoveryReport> _reports = {};
  final Set<String> _probing = {};

  /// 删除被拒的原因（该行显示引用模板名）。
  final Map<String, String> _deleteErrors = {};

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _discovery = widget.discovery ??
        ModelDiscoveryService(configPath: widget.configPath);
  }

  void _replaceConfig(AppConfig next) {
    setState(() => _config = next);
    widget.onConfigChanged?.call(next);
  }

  Future<void> _probe(String name) async {
    setState(() => _probing.add(name));
    ModelDiscoveryReport report;
    try {
      report = await _discovery.discover(_config, name);
    } catch (e) {
      report = ModelDiscoveryReport(
        success: false,
        providerName: name,
        entries: _config.providers[name]?.models ?? const [],
        added: 0,
        updated: 0,
        removed: 0,
        dropped: 0,
        error: '探测异常：$e',
        config: _config,
      );
    }
    if (!mounted) return;
    setState(() {
      _probing.remove(name);
      _reports[name] = report;
    });
    if (report.success) _replaceConfig(report.config);
  }

  Future<void> _openForm({String? originalName}) async {
    final original = originalName == null ? null : _config.providers[originalName];
    final result = await showDialog<_ProviderFormResult>(
      context: context,
      builder: (_) => _ProviderFormDialog(
        originalName: originalName,
        original: original,
        existingNames: _config.providers.keys.toSet(),
      ),
    );
    if (result == null || !mounted) return;
    await _save(result);
  }

  Future<void> _save(_ProviderFormResult result) async {
    final providers = <String, ProviderConfig>{
      for (final entry in _config.providers.entries)
        if (entry.key != result.originalName) entry.key: entry.value,
    };
    final before = result.originalName == null
        ? null
        : _config.providers[result.originalName];

    providers[result.name] = ProviderConfig(
      // 编辑时留空 = 沿用原密钥；新增时表单已强制非空。
      apiKey: result.apiKey.isEmpty && before != null
          ? before.apiKey
          : result.apiKey,
      baseUrl: normalizeBaseUrl(result.baseUrl),
      models: before?.models ?? const [],
      discoveredAt: before?.discoveredAt,
    );

    // 改名：在同一保存动作里改写所有引用旧名的模板 provider 字段。
    final types = Map<String, AgentTypeConfig>.from(_config.agentTypes);
    if (result.originalName != null && result.originalName != result.name) {
      for (final entry in types.entries.toList()) {
        if (entry.value.provider == result.originalName) {
          types[entry.key] = AgentTypeConfig.fromJson(entry.key, {
            ...entry.value.toJson(),
            'provider': result.name,
          });
        }
      }
    }

    final next = _config.copyWith(providers: providers, agentTypes: types);
    try {
      ConfigService.save(next, configPath: widget.configPath);
    } catch (e) {
      _showNotice('保存失败：$e');
      return;
    }
    _replaceConfig(next);
    _deleteErrors.remove(result.name);

    // 保存成功后自动探测一次（新增 / 改名 / 改地址 / 改密钥都算一次保存动作）。
    await _probe(result.name);
  }

  Future<void> _delete(String name) async {
    final refs = <String>[
      for (final entry in _config.agentTypes.entries)
        if (entry.value.provider == name) entry.key,
    ];
    if (refs.isNotEmpty) {
      setState(() {
        _deleteErrors[name] = '被 ${refs.join("、")} 引用，不能删除';
      });
      return;
    }
    final providers = Map<String, ProviderConfig>.from(_config.providers)
      ..remove(name);
    final next = _config.copyWith(providers: providers);
    try {
      ConfigService.save(next, configPath: widget.configPath);
    } catch (e) {
      _showNotice('删除失败：$e');
      return;
    }
    setState(() {
      _reports.remove(name);
      _deleteErrors.remove(name);
    });
    _replaceConfig(next);
  }

  void _showNotice(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = _config.providers.keys.toList();
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.hub_outlined, size: 20),
          SizedBox(width: 8),
          Text('Providers'),
        ],
      ),
      content: SizedBox(
        width: 620,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (names.isEmpty)
              const Text('还没有任何 Provider：点下面的「添加 Provider」开始。')
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: names.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (context, i) => _buildRow(theme, names[i]),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '探测只读取网关的 /v1/models 目录；失败不会清空已有目录，也不会回滚已保存的配置。',
              style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton.icon(
          key: const ValueKey('add-provider'),
          onPressed: () => _openForm(),
          icon: const Icon(Icons.add, size: 18),
          label: const Text('添加 Provider'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('关闭'),
        ),
      ],
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    );
  }

  Widget _buildRow(ThemeData theme, String name) {
    final provider = _config.providers[name]!;
    final report = _reports[name];
    final deleteError = _deleteErrors[name];
    final catalog = provider.discoveredAt == null
        ? '目录 ${provider.models.length} 条 · 未探测'
        : '目录 ${provider.models.length} 条 · 取自 ${provider.discoveredAt}';
    return ListTile(
      key: ValueKey('providers-row-$name'),
      dense: true,
      title: Text(name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('地址：${normalizeBaseUrl(provider.baseUrl)}',
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          Text(catalog,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
          if (report != null)
            Text(
              report.summary,
              key: ValueKey('provider-status-$name'),
              style: TextStyle(
                fontSize: 12,
                color: report.success
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.error,
              ),
            ),
          if (deleteError != null)
            Text(
              deleteError,
              key: ValueKey('provider-delete-error-$name'),
              style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_probing.contains(name))
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            key: ValueKey('provider-probe-$name'),
            icon: const Icon(Icons.refresh, size: 18),
            tooltip: '探测',
            onPressed: _probing.contains(name) ? null : () => _probe(name),
          ),
          IconButton(
            key: ValueKey('provider-edit-$name'),
            icon: const Icon(Icons.edit_outlined, size: 18),
            tooltip: '编辑',
            onPressed: () => _openForm(originalName: name),
          ),
          IconButton(
            key: ValueKey('provider-delete-$name'),
            icon: const Icon(Icons.delete_outline, size: 18),
            tooltip: '删除',
            onPressed: () => _delete(name),
          ),
        ],
      ),
    );
  }
}

class _ProviderFormResult {
  final String? originalName;
  final String name;
  final String baseUrl;
  final String apiKey;

  const _ProviderFormResult({
    required this.originalName,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
  });
}

/// 添加 / 编辑 Provider 的表单。密钥框 `obscureText`，编辑时不回填原值。
class _ProviderFormDialog extends StatefulWidget {
  final String? originalName;
  final ProviderConfig? original;
  final Set<String> existingNames;

  const _ProviderFormDialog({
    this.originalName,
    this.original,
    required this.existingNames,
  });

  @override
  State<_ProviderFormDialog> createState() => _ProviderFormDialogState();
}

class _ProviderFormDialogState extends State<_ProviderFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _urlCtrl;
  late final TextEditingController _keyCtrl;
  String? _error;

  bool get _isEdit => widget.originalName != null;

  @override
  void initState() {
    super.initState();
    _nameCtrl = TextEditingController(text: widget.originalName ?? '');
    _urlCtrl = TextEditingController(text: widget.original?.baseUrl ?? '');
    _keyCtrl = TextEditingController();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写 Provider 名称');
      return;
    }
    final others = widget.existingNames
        .where((n) => n != widget.originalName)
        .toSet();
    if (others.contains(name)) {
      setState(() => _error = 'Provider "$name" 已存在');
      return;
    }
    final rawUrl = _urlCtrl.text.trim();
    final uri = Uri.tryParse(rawUrl);
    if (uri == null ||
        !uri.hasScheme ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty) {
      setState(() => _error = '网关地址必须是以 http:// 或 https:// 开头的绝对地址');
      return;
    }
    final key = _keyCtrl.text.trim();
    if (!_isEdit && key.isEmpty) {
      setState(() => _error = '请填写 API Key');
      return;
    }
    Navigator.of(context).pop(_ProviderFormResult(
      originalName: widget.originalName,
      name: name,
      baseUrl: rawUrl,
      apiKey: key,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑 Provider' : '添加 Provider'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  key: const ValueKey('provider-form-error'),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            TextField(
              key: const ValueKey('provider-name'),
              controller: _nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Provider 名称',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('provider-base-url'),
              controller: _urlCtrl,
              decoration: const InputDecoration(
                labelText: '网关地址',
                hintText: 'http://127.0.0.1:3425',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('provider-api-key'),
              controller: _keyCtrl,
              obscureText: true,
              decoration: InputDecoration(
                labelText: 'API Key',
                hintText: _isEdit ? '留空表示沿用原密钥' : '',
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('provider-form-cancel'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('provider-form-save'),
          onPressed: _submit,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
