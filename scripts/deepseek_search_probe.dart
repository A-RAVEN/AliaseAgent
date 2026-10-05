// 手工验收脚本（tasks.md 3.1 / 3.5 / 4.4 / 7.3 的跨语言那一段）：拿仓库根的
// `sidecar.dll` 真跑一遍"配置进去 → 可用后端清单出来"，用来核对
// `deepseek` 后端到底有没有被认出来。
//
// 为什么单独一个脚本而不是 Dart 测试：搜索初始化在每个进程里只跑一次
// （C++ 侧 `std::call_once`），`flutter test` 会把多个测试文件放进同一个进程，
// 于是"我这份配置到底生效了没"取决于谁先跑。这个脚本是**独立进程**，一跑就是
// 干净的初始状态，所以它的读数能直接当判据。
//
// 用法（在仓库根）：
//   dart run scripts/deepseek_search_probe.dart
//   dart run scripts/deepseek_search_probe.dart --no-deepseek-section
//   dart run scripts/deepseek_search_probe.dart --session-base https://api.deepseek.com/anthropic
//   dart run scripts/deepseek_search_probe.dart --search "查询词"        # 真搜一次（花钱）
//
// 不加 `--search` 时只读可用后端清单，**不发起任何搜索**（不花钱、不需要联网）。
// 加 `--search <查询>` 时用 `~/.aliasagent/config.json` 里的**真实配置**（含会话
// 模型的地址与密钥，与 `lib/main.dart` 交下去的那份一致）真跑一次 `web_search`，
// 只发给 `deepseek` 这一个后端，用来做手工验收。
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _EnsureNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _EnsureDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NoArgNative = Pointer<Utf8> Function();
typedef _NoArgDart = Pointer<Utf8> Function();

/// 读返回值。**不要释放**这个指针：返回值由 sidecar 自己持有（与
/// `lib/services/sidecar_bridge.dart` 里各调用点的做法一致），用 Dart 的 malloc
/// 去 free 它会直接崩进程。只释放我们自己传进去的参数指针。
String _take(Pointer<Utf8> p) {
  if (p == nullptr) return '<null>';
  return p.toDartString();
}

void main(List<String> argv) {
  final dllPath = File('sidecar.dll').absolute.path;
  if (!File(dllPath).existsSync()) {
    stderr.writeln('找不到 $dllPath —— 先跑 scripts\\sync_sidecar_dll.ps1');
    exitCode = 2;
    return;
  }

  final withSection = !argv.contains('--no-deepseek-section');
  final withOwnKey = !argv.contains('--no-own-key');
  final ownKey = _argValue(argv, '--own-key') ?? 'sk-自己写的（占位）';
  final ownBase = _argValue(argv, '--own-base') ?? '';
  final sessionBase = _argValue(argv, '--session-base') ??
      'https://api.deepseek.com/anthropic';
  final sessionKey = _argValue(argv, '--session-key') ?? 'sk-会话模型那把（占位）';

  // ---- `--search <查询>`：用**真实配置**真搜一次（要花钱，只在手工验收时用）----
  // 配置按 lib/main.dart 实际交下去的那份组装：config.search + session_model。
  Map<String, dynamic>? realSearch;
  if (argv.contains('--search')) {
    final override = Platform.environment['ALIASAGENT_CONFIG'];
    final cfgFile = File(override != null && override.isNotEmpty
        ? override
        : '${Platform.environment['USERPROFILE'] ?? ''}\\.aliasagent\\config.json');
    if (!cfgFile.existsSync()) {
      stderr.writeln('找不到配置文件 ${cfgFile.path}');
      exitCode = 2;
      return;
    }
    final appCfg = jsonDecode(cfgFile.readAsStringSync()) as Map<String, dynamic>;
    final searchSection = (appCfg['search'] as Map<String, dynamic>?) ?? {};
    final providerName =
        ((appCfg['agent_types'] as Map)['general'] as Map)['provider'] as String;
    final provider =
        ((appCfg['providers'] as Map)[providerName] as Map).cast<String, dynamic>();
    realSearch = <String, dynamic>{
      ...searchSection,
      'session_model': <String, dynamic>{
        'base_url': provider['base_url'],
        'api_key': provider['api_key'],
      },
    };
    // `--search` 模式下也允许把地址/密钥临时盖掉（用来核对"地址不可达"这类边界）
    if (ownBase.isNotEmpty || !withOwnKey) {
      final ds = <String, dynamic>{
        ...((realSearch['deepseek'] as Map<String, dynamic>?) ?? const {}),
      };
      if (ownBase.isNotEmpty) ds['base_url'] = ownBase;
      if (!withOwnKey) ds['api_key'] = ownKey;
      realSearch['deepseek'] = ds;
    }
  }

  final lib = DynamicLibrary.open(dllPath);
  final setWorkspace = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
      Pointer<Utf8> Function(Pointer<Utf8>)>('set_workspace');
  final ensure = lib.lookupFunction<_EnsureNative, _EnsureDart>('ensure_search_infra');
  final providers =
      lib.lookupFunction<_NoArgNative, _NoArgDart>('get_search_providers');

  final wsPtr = Directory.current.path.toNativeUtf8();
  final wsResult = _take(setWorkspace(wsPtr));
  malloc.free(wsPtr);

  final config = realSearch ??
      <String, dynamic>{
        if (withSection)
          'deepseek': <String, dynamic>{
            if (withOwnKey) 'api_key': ownKey,
            if (ownBase.isNotEmpty) 'base_url': ownBase,
          },
        'session_model': <String, dynamic>{
          'base_url': sessionBase,
          'api_key': sessionKey,
        },
      };
  final configJson = jsonEncode(config);

  // ignore: avoid_print
  print('[探针] 动态库: $dllPath');
  // ignore: avoid_print
  print('[探针] set_workspace 返回: $wsResult');
  // ignore: avoid_print
  print('[探针] 交给搜索初始化的配置: $configJson');

  final cfgPtr = configJson.toNativeUtf8();
  final initResult = _take(ensure(cfgPtr));
  malloc.free(cfgPtr);
  // ignore: avoid_print
  print('[探针] ensure_search_infra 返回: $initResult');

  final listJson = _take(providers());
  // ignore: avoid_print
  print('[探针] 可用后端清单: $listJson');

  final list = jsonDecode(listJson) as List<dynamic>;
  final names = list.map((e) => (e as Map)['name']).toList();
  final hasDeepseek = names.contains('deepseek');
  // ignore: avoid_print
  print('[探针] 后端名: $names');
  // ignore: avoid_print
  print('[探针] 是否含 deepseek: $hasDeepseek');
  // 一句话结论（用户文档里的排错步骤就照这一行读）
  // ignore: avoid_print
  print(hasDeepseek
      ? '[探针] 结论：DeepSeek 搜索可用（清单里有 deepseek，界面上的 web_search 也会出现）'
      : '[探针] 结论：DeepSeek 搜索不可用（清单：$names）。'
          '要启用：把 providers 里那个地址指向 api.deepseek.com，并在配置里写 "search": {"deepseek": {}}');

  // ---- 真搜一次（只在 `--search` 下）：走 web_search 那个入口 ----
  if (realSearch != null) {
    final query = _argValue(argv, '--search')!;
    final maxResults = int.tryParse(_argValue(argv, '--max-results') ?? '') ?? 5;
    final webSearch = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>),
        Pointer<Utf8> Function(Pointer<Utf8>)>('web_search');
    final reqPtr = jsonEncode({
      'query': query,
      'max_results': maxResults,
      'providers': ['deepseek'],
    }).toNativeUtf8();
    final started = DateTime.now();
    final searchResult = _take(webSearch(reqPtr));
    final elapsed = DateTime.now().difference(started);
    malloc.free(reqPtr);

    // ignore: avoid_print
    print('[搜索] 查询: $query（上限 $maxResults 条）');
    // ignore: avoid_print
    print('[搜索] 耗时: ${elapsed.inMilliseconds}ms');
    final decoded = jsonDecode(searchResult);
    // ignore: avoid_print
    print('[搜索] 原始返回（截断到 1200 字）: '
        '${searchResult.length > 1200 ? "${searchResult.substring(0, 1200)}…" : searchResult}');
    if (decoded is Map && decoded['results'] is Map) {
      final byProvider = decoded['results'] as Map;
      for (final name in byProvider.keys) {
        final entry = byProvider[name] as Map;
        final items = (entry['results'] as List?) ?? const [];
        // ignore: avoid_print
        print('[搜索] 后端 $name 返回 ${items.length} 条'
            '${entry['error'] != null ? "，错误：${entry['error']}" : ""}');
        for (var i = 0; i < items.length; i++) {
          final it = items[i] as Map;
          final content = (it['content'] as String?) ?? '';
          // ignore: avoid_print
          print('[搜索]   ${i + 1}. ${it['title']}');
          // ignore: avoid_print
          print('[搜索]      ${it['url']}');
          // ignore: avoid_print
          print('[搜索]      正文 ${content.length} 字：'
              '${content.length > 60 ? "${content.substring(0, 60)}…" : content}');
        }
      }
    }
  }
}

String? _argValue(List<String> argv, String flag) {
  final i = argv.indexOf(flag);
  if (i < 0 || i + 1 >= argv.length) return null;
  return argv[i + 1];
}
