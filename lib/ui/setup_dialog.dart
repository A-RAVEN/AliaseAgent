import 'package:flutter/material.dart';

import '../models/agent_type_config.dart';
import '../models/app_config.dart';
import '../models/model_catalog_entry.dart';
import '../models/provider_config.dart';
import '../services/config_service.dart';
import '../services/model_discovery_service.dart';
import '../services/tool_catalog.dart';

/// 首启 / 补问的两步向导（change `add-provider-model-discovery` 任务 5.1；
/// change `model-truth-from-gateway` D2/D3 改造）。
///
/// 第 1 步：Provider 名字 / 网关地址 / 密钥。
/// 第 2 步：**探测门**——当场探测 `GET {base_url}/v1/models`，探测成功且目录非空才
/// 显示模型下拉并放行 `Start`；缺省模型 = 目录第一项（网关顺序，本产品不排序），
/// 下拉可改（显示 `display_name`、存 `id`）。探测到的目录在**同一次保存**里写回
/// `providers.<名>.models`（`ModelCatalogEntry` 形状，窗口键 `context_window`）与
/// `discovered_at`，此后运行时的窗口解析与脏值判定都有事实源。
///
/// **为什么能砍掉原来的"上下文窗口"输入步（原注释说"那一步是补问触发条件，不能被
/// 砍掉"）**：窗口的事实来源已经改成网关目录（见 `agent-config` 的「生效上下文窗口
/// 的解析顺序」），配置里的 `max_context_tokens` 从"必填"降为"目录缺失时的覆盖值"，
/// **缺席是合法状态**。所以那条"缺 `max_context_tokens` ⇒ 再弹一次补问"的判据不再
/// 成立（留着它会在完全合法的配置上反复弹窗）。这条触发已从 `lib/main.dart` 删除，
/// 删除后产品里只剩"配置文件不存在"这一个自动入口（补问路径另外还用于合并既有
/// 配置）。写出的首启配置**不含** `max_context_tokens` 键，也不含任何硬编码模型 id。
///
/// 代价如实写在这里：**首启要求网关可达**。探测不通/目录为空就完不成首启，错误文案
/// 给出路（先起网关，再去 Providers 页探测）。这是"模型名与窗口都来自目录"的必然
/// 代价，不是缺陷。
class SetupDialog extends StatefulWidget {
  final VoidCallback onComplete;
  final void Function(AppConfig)? saveConfig;

  /// 已经加载到的现有配置（首启补问时非空）。
  ///
  /// 补问只缺密钥（或 Provider 配置不完整），**不许**拿一份新的缺省配置整份覆盖：
  /// providers、search、spill 与其它模板都要合并保留。首启时传 null。
  final AppConfig? existingConfig;

  /// 探测动作；注入假实现供 widget 测试使用。null = 真实的 HTTP 探测。
  ///
  /// 这里注入的是**探测**本身（[ModelCatalogProbe.fetch]），而不是 Providers 页用的
  /// [ProviderCatalogDiscovery]：后者一调用就 `ConfigService.save` 写盘，而向导必须
  /// 在 `Start` 那一刻才落盘（探测中途失败不能留下半份配置）。
  final ModelCatalogProbe? probe;

  /// 可注入时钟（`discovered_at` 的取值；测试用于断言非空/形状）。
  final DateTime Function()? clock;

  const SetupDialog({
    super.key,
    required this.onComplete,
    this.saveConfig,
    this.existingConfig,
    this.probe,
    this.clock,
  });

  @override
  State<SetupDialog> createState() => _SetupDialogState();
}

class _SetupDialogState extends State<SetupDialog> {
  static const int _stepProvider = 0;
  static const int _stepModel = 1;

  /// 首启默认 Provider：名字 → 标准 API 端点（与 `Docs/user-guide/configuration.md`
  /// 里的示例一致）。名字是用户可改的默认值，不是写死的唯一供应商。
  ///
  /// 用户 2026-11-04 裁定：默认改用本机 magpie 网关（`http://127.0.0.1:3425`），
  /// 不再沿用 `anthropic` / `https://api.anthropic.com`。
  static const Map<String, String> kFirstRunDefaults = {
    'magpie': 'http://127.0.0.1:3425',
  };

  /// 首启默认密钥：magpie 网关的密钥约定就叫 `magpie`（用户 2026-11-04 原话
  /// 「另外 magpie 的APIkey 就叫 magpie」）。补问不回填旧密钥，保持空白。
  static const String kFirstRunDefaultApiKey = 'magpie';

  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();
  final _keyCtrl = TextEditingController();

  late final ModelCatalogProbe _probe;
  late final DateTime Function() _clock;

  /// 打开时 `general` 实际在用的 provider 名；补问时"写回它"，首启是 `magpie`。
  late final String _initialProviderName;

  int _step = _stepProvider;
  String? _error;
  bool _saving = false;
  bool _probing = false;

  /// 本次探测成功拿到的目录（空 = 还没探测 / 探测失败）。
  List<ModelCatalogEntry> _catalog = const [];
  String? _selectedModelId;

  bool get _isFollowUp => widget.existingConfig != null;

  @override
  void initState() {
    super.initState();
    _probe = widget.probe ?? HttpModelCatalogProbe();
    _clock = widget.clock ?? DateTime.now;
    final general = widget.existingConfig?.agentTypes['general'];
    _initialProviderName =
        (general != null && general.provider.isNotEmpty) ? general.provider : 'magpie';
    _nameCtrl.text = _initialProviderName;
    final existingProvider =
        widget.existingConfig?.providers[_initialProviderName];
    _urlCtrl.text = (existingProvider != null && existingProvider.baseUrl.isNotEmpty)
        ? existingProvider.baseUrl
        : (kFirstRunDefaults[_initialProviderName] ??
            kFirstRunDefaults.values.first);
    // 首启预填 magpie 的约定密钥；补问保持空白（旧密钥不回显、要重新输入）。
    _keyCtrl.text = _isFollowUp ? '' : kFirstRunDefaultApiKey;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    super.dispose();
  }

  /// 第一步校验 + 进入第二步并执行探测。失败时点名字段、保留其它输入、停在第一步。
  Future<void> _nextStep() async {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写 Provider 名称');
      return;
    }
    final otherNames = (widget.existingConfig?.providers.keys ?? const <String>[])
        .where((n) => n != _initialProviderName)
        .toSet();
    if (otherNames.contains(name)) {
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
    final apiKey = _keyCtrl.text.trim();
    if (apiKey.isEmpty) {
      setState(() => _error = 'Please enter an API key');
      return;
    }

    setState(() {
      _error = null;
      _step = _stepModel;
      _probing = true;
      _catalog = const [];
      _selectedModelId = null;
    });

    ModelCatalogProbeResult result;
    try {
      result = await _probe.fetch(
        baseUrl: rawUrl,
        apiKey: apiKey,
        previewChars: widget.existingConfig?.spillPreviewChars ??
            AppConfig.kDefaultSpillPreviewChars,
      );
    } catch (e) {
      result = ModelCatalogProbeResult.failure('探测异常：$e');
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      if (!result.ok) {
        _error = '探测失败：${result.error ?? "未知原因"}。'
            '首启要求网关可达并返回模型目录：先起网关，或到 Providers 页探测后重开向导';
        return;
      }
      if (result.entries.isEmpty) {
        _error = '探测成功但目录为空：这个网关没有返回任何模型，无法确定模型名与上下文窗口';
        return;
      }
      _catalog = result.entries;
      _selectedModelId = result.entries.first.id;
    });
  }

  Future<void> _submit() async {
    if (_step == _stepProvider) {
      await _nextStep();
      return;
    }
    if (_probing || _saving) return;
    if (_catalog.isEmpty || _selectedModelId == null) {
      // 探测失败的原始原因要留着（它才是用户能行动的信息），不要用一句笼统的
      // "还没探测" 盖掉它。
      setState(() => _error ??= '探测还没成功：目录为空时无法确定模型与上下文窗口');
      return;
    }

    setState(() => _saving = true);
    final config = _mergeConfig(
      providerName: _nameCtrl.text.trim(),
      baseUrl: _urlCtrl.text.trim(),
      apiKey: _keyCtrl.text.trim(),
      catalog: _catalog,
      selectedModelId: _selectedModelId!,
    );
    if (widget.saveConfig != null) {
      widget.saveConfig!(config);
    } else {
      ConfigService.save(config);
    }

    widget.onComplete();
  }

  /// 把这次输入**合并**到现有配置上：Provider 三要素 + 探测到的目录 + `discovered_at`，
  /// 其余原样保留。补问时若改了 Provider 名，所有引用旧名的模板在同一次写回里改过去，
  /// 不留悬空引用。
  ///
  /// 首启（没有既有 `general`）才写 `general.model`；补问**不碰**模型字段，也**不碰**
  /// `max_context_tokens`（缺席合法、有值则是覆盖值，都不是向导该改的东西）。
  AppConfig _mergeConfig({
    required String providerName,
    required String baseUrl,
    required String apiKey,
    required List<ModelCatalogEntry> catalog,
    required String selectedModelId,
  }) {
    final existing = widget.existingConfig;
    final providers = <String, ProviderConfig>{
      ...?existing?.providers,
    };
    providers[providerName] = ProviderConfig(
      apiKey: apiKey,
      baseUrl: normalizeBaseUrl(baseUrl),
      models: catalog,
      discoveredAt: _clock().toUtc().toIso8601String(),
    );
    if (providerName != _initialProviderName && existing != null) {
      providers.remove(_initialProviderName);
    }

    final types = <String, AgentTypeConfig>{
      ...?existing?.agentTypes,
    };
    if (providerName != _initialProviderName) {
      for (final entry in types.entries.toList()) {
        if (entry.value.provider == _initialProviderName) {
          types[entry.key] = AgentTypeConfig.fromJson(entry.key, {
            ...entry.value.toJson(),
            'provider': providerName,
          });
        }
      }
    }

    final general = types['general'];
    if (general == null) {
      types['general'] = AgentTypeConfig(
        name: 'general',
        provider: providerName,
        // 模型名来自**本次探测的目录**（第一项是下拉缺省，用户可改）；产品里没有任何
        // 硬编码模型串。
        model: selectedModelId,
        systemPrompt: 'You are a helpful assistant.',
        // 首启默认清单覆盖当前基础工具（不是旧版那两项）。
        tools: ToolCatalog.kBaseToolNames,
        // 默认只有文本，图片不发（模型能不能看图由这一项声明，见
        // Docs/user-guide/configuration.md 的 input_modalities）。
        inputModalities: AgentTypeConfig.kDefaultInputModalities,
        // 刻意不写 max_context_tokens：缺席 = 窗口取网关目录值。
      );
    } else if (general.provider != providerName) {
      types['general'] = AgentTypeConfig.fromJson('general', {
        ...general.toJson(),
        'provider': providerName,
      });
    }

    return (existing ?? const AppConfig(version: 1))
        .copyWith(providers: providers, agentTypes: types);
  }

  @override
  Widget build(BuildContext context) {
    final busy = _saving || _probing;
    return AlertDialog(
      title: const Text('Welcome to AliasAgent'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _step == _stepProvider
                ? '第 1 步 / 共 2 步：填一个 Provider（名字、网关地址、密钥）。'
                : '第 2 步 / 共 2 步：选模型（来自网关目录；模型名与上下文窗口都从目录读）。',
          ),
          const SizedBox(height: 16),
          if (_step == _stepProvider) ..._providerFields() else _modelField(),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              key: const ValueKey('setup-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        if (_step == _stepModel)
          TextButton(
            key: const ValueKey('setup-back'),
            onPressed: busy ? null : () => setState(() => _step = _stepProvider),
            child: const Text('上一步'),
          ),
        TextButton(
          key: ValueKey(_step == _stepProvider ? 'setup-next' : 'setup-start'),
          onPressed: busy ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_step == _stepProvider ? '下一步' : 'Start'),
        ),
      ],
    );
  }

  List<Widget> _providerFields() => [
        TextField(
          key: const ValueKey('setup-provider-name'),
          controller: _nameCtrl,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: 'Provider 名称',
            hintText: 'magpie',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('setup-base-url'),
          controller: _urlCtrl,
          enabled: !_saving,
          decoration: const InputDecoration(
            labelText: '网关地址',
            hintText: 'http://127.0.0.1:3425',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const ValueKey('setup-api-key'),
          controller: _keyCtrl,
          enabled: !_saving,
          obscureText: true,
          decoration: InputDecoration(
            labelText: 'API Key',
            hintText: _isFollowUp ? '重新输入密钥（不会回显旧值）' : 'magpie',
            border: const OutlineInputBorder(),
          ),
        ),
      ];

  Widget _modelField() {
    if (_probing) {
      return Row(
        key: const ValueKey('setup-probing'),
        children: const [
          SizedBox(
              width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('正在探测网关目录…'),
        ],
      );
    }
    if (_catalog.isEmpty) {
      return const Text('还没有可用的目录：探测失败时无法选模型。');
    }
    return DropdownButtonFormField<String>(
      key: const ValueKey('setup-model'),
      initialValue: _selectedModelId,
      isExpanded: true,
      decoration: const InputDecoration(
        labelText: '模型',
        helperText: '缺省是目录第一项；发送时的上下文窗口也取自这里',
        border: OutlineInputBorder(),
      ),
      items: [
        for (final entry in _catalog)
          DropdownMenuItem(
            value: entry.id,
            child: Text(entry.displayName ?? entry.id,
                overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: _saving
          ? null
          : (value) => setState(() => _selectedModelId = value),
    );
  }
}
