import 'package:flutter_test/flutter_test.dart';

import 'package:alias_agent/services/tool_catalog.dart';

/// 工具目录（change `add-agent-object-and-templates` 任务 1.3）。
///
/// 固定的是：目录是读取工具定义的唯一入口、未知名字必须显式报错并列名、
/// 条件注册与读取看到的是同一份真相。
void main() {
  Map<String, dynamic> def(String name) => {
        'name': name,
        'description': 'definition of $name',
        'input_schema': {
          'type': 'object',
          'properties': {},
          'required': [],
        },
      };

  setUp(() => ToolCatalog.instance.reset());
  tearDown(() => ToolCatalog.instance.reset());

  test('注册与读取的是同一份目录：names 与 definitions 的键完全一致', () {
    ToolCatalog.instance.seed({
      'alpha': def('alpha'),
      'beta': def('beta'),
    });
    final names = ToolCatalog.instance.names;
    final defs = ToolCatalog.instance.definitions;
    // ignore: avoid_print
    print('  [OBS] names=$names definitions键=${defs.keys.toList()} '
        '每个定义的 name 字段=${defs.values.map((d) => d['name']).toList()}');
    expect(names, ['alpha', 'beta']);
    expect(defs.keys.toList(), names);
    expect(defs.values.every((d) => names.contains(d['name'])), isTrue,
        reason: '目录里的键必须与定义自己的 name 对得上，否则读取方会认错工具');
    expect(ToolCatalog.instance.definition('alpha'), same(defs['alpha']));
  });

  test('未知工具名必须显式报错并列出名字，不静默过滤', () {
    ToolCatalog.instance.seed({'alpha': def('alpha')});
    var message = '';
    try {
      ToolCatalog.instance.resolve(['alpha', 'nope', 'also_missing']);
      fail('未知工具必须让解析失败，不许只把 known 的返回');
    } on UnknownToolsException catch (e) {
      message = e.toString();
      expect(e.names, ['nope', 'also_missing']);
    }
    // ignore: avoid_print
    print('  [OBS] 未知工具报错=$message');
    expect(message, contains('nope'));
    expect(message, contains('also_missing'));
    expect(message, contains('不会静默丢弃'));
  });

  test('解析按模板清单的顺序返回定义，并只返回清单里的工具', () {
    ToolCatalog.instance.seed({
      'alpha': def('alpha'),
      'beta': def('beta'),
      'gamma': def('gamma'),
    });
    final resolved = ToolCatalog.instance.resolve(['gamma', 'alpha']);
    // ignore: avoid_print
    print('  [OBS] 模板清单 [gamma, alpha] -> '
        '${resolved.map((d) => d['name']).toList()}');
    expect(resolved.map((d) => d['name']).toList(), ['gamma', 'alpha']);
  });

  test('目录对外只读：改返回的集合不会改到目录本体', () {
    ToolCatalog.instance.seed({'alpha': def('alpha')});
    expect(() => ToolCatalog.instance.names.add('x'), throwsUnsupportedError);
    expect(() => ToolCatalog.instance.definitions['x'] = def('x'),
        throwsUnsupportedError);
    expect(() => ToolCatalog.instance.nameSet.add('x'), throwsUnsupportedError);
    expect(ToolCatalog.instance.names, ['alpha']);
  });

  test('条件注册可追加工具；reset 之后目录为空', () {
    ToolCatalog.instance.seed({'alpha': def('alpha')});
    ToolCatalog.instance.registerDynamic('web_search', def('web_search'));
    // ignore: avoid_print
    print('  [OBS] 条件注册后=${ToolCatalog.instance.names}');
    expect(ToolCatalog.instance.names, ['alpha', 'web_search']);
    ToolCatalog.instance.reset();
    expect(ToolCatalog.instance.names, isEmpty);
  });

  test('基础工具名覆盖当前十项基础能力', () {
    // ignore: avoid_print
    print('  [OBS] 基础工具=${ToolCatalog.kBaseToolNames}');
    expect(ToolCatalog.kBaseToolNames.length, 10);
    expect(
        ToolCatalog.kBaseToolNames,
        containsAll([
          'read_file',
          'write_file',
          'edit_file',
          'list_dir',
          'get_current_time',
          'glob_file',
          'grep_file',
          'read_image',
          'run_command',
          'read_spill',
        ]));
  });

  test('旧默认清单只认"恰好 read_file + list_dir 两项"这一种形状', () {
    // ignore: avoid_print
    print('  [OBS] 旧形状判定：两项=${ToolCatalog.isLegacyDefaultTools(['read_file', 'list_dir'])} '
        '顺序反转=${ToolCatalog.isLegacyDefaultTools(['list_dir', 'read_file'])} '
        '三项=${ToolCatalog.isLegacyDefaultTools(['read_file', 'list_dir', 'run_command'])} '
        '一项=${ToolCatalog.isLegacyDefaultTools(['read_file'])}');
    expect(ToolCatalog.isLegacyDefaultTools(['read_file', 'list_dir']), isTrue);
    expect(ToolCatalog.isLegacyDefaultTools(['list_dir', 'read_file']), isTrue);
    expect(
        ToolCatalog.isLegacyDefaultTools(['read_file', 'list_dir', 'run_command']),
        isFalse);
    expect(ToolCatalog.isLegacyDefaultTools(['read_file']), isFalse);
  });
}
