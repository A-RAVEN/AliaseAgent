import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 用户文档 ↔ 代码 的一致性检查（change `add-user-docs`，design D4）。
///
/// 这个测试**只核对名字对不对得上**，不判断"说明写得准不准"—— 后者写不成一条
/// 能失败的断言（只能写成恒真的"文档非空"），所以不写。内容准不准靠人读。
///
/// 五条检查：
///   ① `Docs/user-guide/` 下每份文档都在 README 的功能索引里被链接；
///   ② README 索引里链的每个文件都真实存在（与①合起来即"双向一致"）；
///   ③ 文档里出现的配置键，都能在产品代码的配置解析路径里找到；
///   ④ 文档里出现的工具名与工具参数名，都能在 `lib/main.dart` 的工具定义里找到；
///   ⑤ 反向：代码里注册的每个工具名、代码里解析的每个配置键，都必须在文档里出现过
///      （加了工具或配置键却不写文档 ⇒ 红）。
///
/// 断言前逐条打印现场：找到几份文档、索引里有几条、每个名字在哪儿找到的。

/// 用户文档所在目录（相对仓库根）。
const _userGuideDir = 'Docs/user-guide';

/// README 里功能索引那一节的标题。
const _indexHeading = '## 功能文档索引';

/// 产品代码里"配置键的解析路径"，Dart 侧。文档中的配置键必须能在这些文件里找到。
const _dartConfigSourcePaths = <String>[
  'lib/models/app_config.dart', // version / providers / agent_types / search
  'lib/models/agent_type_config.dart', // provider / model / system_prompt / tools / ...
  'lib/models/provider_config.dart', // api_key / base_url
  // 第一次启动的对话框写出的那份配置：providers 里的键名 anthropic、
  // agent_types 里的键名 general 都在这里写出来。
  'lib/ui/setup_dialog.dart',
];

/// 产品代码里"配置键的解析路径"，C++ 侧（`search` 段里各搜索服务的键）。
/// 只取"读配置"那一段函数，不取同一个文件里"拼响应"用的键（那些不是配置键）。
const _cppConfigSourcePaths = <String>[
  'sidecar/src/search_provider.cpp',
];
const _cppConfigRegionStart = 'ensure_search_infra_impl';
const _cppConfigRegionEnd = 'get_search_providers_json';

/// 工具定义所在文件。
const _mainDartPath = 'lib/main.dart';

/// 工具定义那一段的起止标记（用标记而不是行号，行号会被后续编辑顶偏）。
const _toolRegionStart = 'final base = <String, Map<String, dynamic>>{';
const _toolRegionEnd = '_toolDefs = base;';

/// 文档里允许出现的、既不是配置键也不是工具/参数名，但确实是代码里存在的名字。
/// 每条都要写清"它在哪个文件里出现"，测试会逐条去该文件里核对 —— 核对不上的条目
/// 会让测试变红，所以这份清单自己也会腐烂不了。
const _otherCodeNames = <String, String>{
  // 可用性探测：启动时问一次"本机浏览器能不能用"，用来决定四个浏览器工具要不要
  // 注册。模型不能调用它，它不是工具。
  'browser_available': 'lib/services/sidecar_bridge.dart',
};

void main() {
  group('用户文档与代码的一致性', () {
    test('README 的功能索引与 Docs/user-guide/ 双向一致', () {
      final docsDir = Directory(_userGuideDir);
      final readme = File('README.md').readAsStringSync();

      // ---- 现场：目录里有哪些文档 ----
      final docFiles = <String>[];
      if (docsDir.existsSync()) {
        for (final f in docsDir.listSync().whereType<File>()) {
          final n = f.uri.pathSegments.last;
          if (n.endsWith('.md')) docFiles.add(n);
        }
      }
      docFiles.sort();
      // ignore: avoid_print
      print('[文档] $_userGuideDir 下共 ${docFiles.length} 份：$docFiles');

      // ---- 现场：README 索引里链了哪些文档 ----
      final headingAt = readme.indexOf(_indexHeading);
      // ignore: avoid_print
      print('[索引] README 里 "$_indexHeading" 出现在第 '
          '${headingAt < 0 ? '(缺失)' : '${readme.substring(0, headingAt).split('\n').length} 行'}');
      final linkPattern =
          RegExp(r'\]\((?:\./)?' + RegExp.escape(_userGuideDir) + r'/([A-Za-z0-9._-]+\.md)\)');
      final linked = linkPattern
          .allMatches(readme)
          .map((m) => m.group(1)!)
          .toSet()
          .toList()
        ..sort();
      // ignore: avoid_print
      print('[索引] 链了 ${linked.length} 份：$linked');

      expect(headingAt >= 0, isTrue,
          reason: 'README 里找不到功能索引那一节（标题应为 "$_indexHeading"）');
      expect(docFiles, isNotEmpty,
          reason: '$_userGuideDir 下没有任何使用文档 —— 每个面向用户的功能都要有一份');

      // ---- ① 目录 → 索引 ----
      final missingFromIndex =
          docFiles.where((n) => !linked.contains(n)).toList();
      // ignore: avoid_print
      print('[① 目录里有、索引里没链] $missingFromIndex');
      expect(missingFromIndex, isEmpty,
          reason: '这些文档存在但 README 索引里没有链接：$missingFromIndex');

      // ---- ② 索引 → 目录 ----
      final missingOnDisk =
          linked.where((n) => !docFiles.contains(n)).toList();
      // ignore: avoid_print
      print('[② 索引里链了、磁盘上没有] $missingOnDisk');
      expect(missingOnDisk, isEmpty,
          reason: 'README 索引链了不存在的文件：$missingOnDisk');
    });

    test('文档里的配置键都能在代码的配置解析路径里找到', () {
      final configKeys = _configKeysFromCode();
      final configKeyList = configKeys.toList()..sort();
      // ignore: avoid_print
      print('[代码] 配置解析路径里的键（${configKeys.length} 个）：$configKeyList');

      final docFiles = _docFiles();
      expect(docFiles, isNotEmpty, reason: '$_userGuideDir 下没有任何使用文档');

      // 文档里"当成配置键写出来"的地方 = ```json 代码块里形如 "键": 的行。
      final usedKeys = <String, List<String>>{}; // 键 → 出现在哪些文档
      for (final file in docFiles) {
        for (final key in _jsonKeysInFencedBlocks(file.readAsStringSync())) {
          usedKeys.putIfAbsent(key, () => []).add(_name(file));
        }
      }
      // ignore: avoid_print
      print('[文档] 当成配置键写出来的 ${usedKeys.length} 个：');
      for (final entry in usedKeys.entries) {
        final known = configKeys.contains(entry.key);
        // ignore: avoid_print
        print('    ${entry.key} ← ${entry.value.join(", ")}'
            '${known ? "" : "   ← 代码里找不到"}');
      }

      // ---- ③ 文档 → 代码 ----
      final unknown =
          usedKeys.keys.where((k) => !configKeys.contains(k)).toList()..sort();
      expect(unknown, isEmpty,
          reason: '这些键在文档里当成配置键写，但代码的配置解析路径里没有：$unknown');

      // ---- ⑤ 反向：代码 → 文档 ----
      final undocumented =
          configKeys.where((k) => !usedKeys.containsKey(k)).toList()..sort();
      // ignore: avoid_print
      print('[⑤ 代码里有、文档里没写] $undocumented');
      expect(undocumented, isEmpty,
          reason: '代码解析这些配置键，但没有一份文档把它们写成配置键：$undocumented');
    });

    test('文档里的工具名与工具参数名都能在工具定义里找到', () {
      final registered = _registeredToolNames();
      final definitionNames = _toolDefinitionNames();
      final registeredList = registered.toList()..sort();
      final definitionList = definitionNames.toList()..sort();
      // ignore: avoid_print
      print('[代码] 注册的工具（${registered.length} 个）：$registeredList');
      // ignore: avoid_print
      print('[代码] 工具定义里出现的名字（${definitionNames.length} 个）：$definitionList');

      final docFiles = _docFiles();
      expect(docFiles, isNotEmpty, reason: '$_userGuideDir 下没有任何使用文档');

      // 文档里用反引号写出来的、形如 read_file / offset 的名字。
      final mentioned = <String, List<String>>{};
      for (final file in docFiles) {
        for (final name in _backtickedCodeNames(file.readAsStringSync())) {
          mentioned.putIfAbsent(name, () => []).add(_name(file));
        }
      }

      final configKeys = _configKeysFromCode();
      final unresolved = <String>[];
      // ignore: avoid_print
      print('[文档] 反引号里写出的 ${mentioned.length} 个代码名：');
      for (final entry in mentioned.entries) {
        final name = entry.key;
        String? where;
        if (registered.contains(name)) {
          where = '注册的工具';
        } else if (definitionNames.contains(name)) {
          where = '工具定义';
        } else if (configKeys.contains(name)) {
          where = '配置键';
        } else if (_otherCodeNames.containsKey(name)) {
          where = _otherCodeNames[name]!;
        }
        if (where == null) {
          unresolved.add(name);
        }
        // ignore: avoid_print
        print('    $name ← ${entry.value.join(", ")}'
            '${where == null ? "   ← 代码里找不到" : "   ✓ $where"}');
      }

      // ---- ④ 文档 → 代码 ----
      expect(unresolved, isEmpty,
          reason: '这些名字在文档里当成代码名写，但代码里找不到：$unresolved');

      // ---- ⑤ 反向：代码 → 文档 ----
      final undocumented =
          registered.where((t) => !mentioned.containsKey(t)).toList()..sort();
      // ignore: avoid_print
      print('[⑤ 注册了但文档里没提] $undocumented');
      expect(undocumented, isEmpty,
          reason: '这些工具已注册，但没有一份文档提到它们：$undocumented');
    });

    test('额外允许的代码名确实存在于它们声称的文件里', () {
      for (final entry in _otherCodeNames.entries) {
        final file = File(entry.value);
        expect(file.existsSync(), isTrue,
            reason: '${entry.key} 声称出现在 ${entry.value}，但该文件不存在');
        final hit = file.readAsStringSync().contains(entry.key);
        // ignore: avoid_print
        print('[清单] ${entry.key} ← ${entry.value}：${hit ? "找到了" : "没找到"}');
        expect(hit, isTrue,
            reason: '${entry.key} 声称出现在 ${entry.value}，但那里找不到它');
      }
    });
  });
}

// ---------------------------------------------------------------------------
// 从文档里抽名字
// ---------------------------------------------------------------------------

String _name(File f) => f.uri.pathSegments.last;

List<File> _docFiles() {
  final dir = Directory(_userGuideDir);
  if (!dir.existsSync()) return const [];
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.md'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// ```json 代码块里形如 `"键":` 的键（文档中"当成配置键写出来"的地方）。
Set<String> _jsonKeysInFencedBlocks(String markdown) {
  final keys = <String>{};
  var inside = false;
  for (final line in markdown.split('\n')) {
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      inside = !inside && trimmed.toLowerCase().contains('json');
      continue;
    }
    if (!inside) continue;
    final m = RegExp(r'^"([a-z][a-z0-9_]*)"\s*:').firstMatch(trimmed);
    if (m != null) keys.add(m.group(1)!);
  }
  return keys;
}

/// 文档里用反引号写出的、全小写下划线形式的代码名（工具名、参数名、配置键）。
Set<String> _backtickedCodeNames(String markdown) {
  final names = <String>{};
  for (final m in RegExp(r'`([a-z][a-z0-9_]{1,40})`').allMatches(markdown)) {
    names.add(m.group(1)!);
  }
  return names;
}

// ---------------------------------------------------------------------------
// 从代码里抽名字
// ---------------------------------------------------------------------------

/// 代码的配置解析路径里出现的键。
Set<String> _configKeysFromCode() {
  final keys = <String>{};
  for (final path in _dartConfigSourcePaths) {
    final src = _readSource(path);
    // Dart：json['键'] 与 '键':（toJson）
    for (final m in RegExp(r'''\[['"]([a-z][a-z0-9_]*)['"]\]''').allMatches(src)) {
      keys.add(m.group(1)!);
    }
    for (final m in RegExp(r'''['"]([a-z][a-z0-9_]*)['"]\s*:''').allMatches(src)) {
      keys.add(m.group(1)!);
    }
  }
  for (final path in _cppConfigSourcePaths) {
    final full = _readSource(path);
    final start = full.indexOf(_cppConfigRegionStart);
    final end = full.indexOf(_cppConfigRegionEnd);
    expect(start >= 0 && end > start, isTrue,
        reason: '$path 里找不到读配置那一段（标记 "$_cppConfigRegionStart" → "$_cppConfigRegionEnd"）');
    final src = full.substring(start, end);
    // C++：cfg.contains("键") 与 cfg["键"]
    for (final m in RegExp(r'''contains\(\s*"([a-z][a-z0-9_]*)"''').allMatches(src)) {
      keys.add(m.group(1)!);
    }
    for (final m in RegExp(r'''\["([a-z][a-z0-9_]*)"\]''').allMatches(src)) {
      keys.add(m.group(1)!);
    }
  }
  expect(keys.length, greaterThanOrEqualTo(10),
      reason: '从配置解析路径里只认出 ${keys.length} 个键，抽取本身可能坏了');
  return keys;
}

String _readSource(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue,
      reason: '配置解析路径里的 $path 不存在 —— 检查本身需要修');
  return file.readAsStringSync();
}

/// 工具定义那一段的源码（用标记切出来，不用行号）。
String _toolDefinitionRegion() {
  final src = File(_mainDartPath).readAsStringSync();
  final start = src.indexOf(_toolRegionStart);
  expect(start >= 0, isTrue,
      reason: '$_mainDartPath 里找不到工具定义的起点标记 "$_toolRegionStart"');
  final end = src.lastIndexOf(_toolRegionEnd);
  expect(end > start, isTrue,
      reason: '$_mainDartPath 里找不到工具定义的终点标记 "$_toolRegionEnd"');
  final region = src.substring(start, end);
  // ignore: avoid_print
  print('[代码] 工具定义那一段共 ${region.split('\n').length} 行');
  return region;
}

/// 真正注册给模型的工具名（工具定义里的 `'name': 'x'`）。
Set<String> _registeredToolNames() {
  final names = <String>{};
  for (final m in RegExp(r"'name':\s*'([a-z][a-z0-9_]*)'")
      .allMatches(_toolDefinitionRegion())) {
    names.add(m.group(1)!);
  }
  expect(names.length, greaterThanOrEqualTo(13),
      reason: '只认出 ${names.length} 个工具，抽取本身可能坏了');
  return names;
}

/// 工具定义里出现的所有名字（工具名 + 输入参数名 + schema 自身的键 + 枚举取值）。
Set<String> _toolDefinitionNames() {
  final region = _toolDefinitionRegion();
  final names = <String>{};
  for (final m in RegExp(r"'([a-z][a-z0-9_]*)':").allMatches(region)) {
    names.add(m.group(1)!);
  }
  // 枚举取值（例如 depth 的 basic / deep）也是文档里会写出来的名字。
  for (final m in RegExp(r"'([a-z][a-z0-9_]*)'").allMatches(region)) {
    names.add(m.group(1)!);
  }
  return names;
}
