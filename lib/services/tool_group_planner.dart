/// 一轮内工具调用的执行分组计划（change `parallelize-readonly-tool-calls`）。
///
/// 依据 design D1 / D6：
///   - 同一轮里**连续**的只读工具调用合并成一个并发段；
///   - 只读段长度为 1 时仍按逐个段执行（段长 1 走原来的同步路径，时序零回归）；
///   - 写类 / 有状态工具，以及**任何不在只读集合里的名字**，各自单独成段（默认串行，
///     将来新加的工具没归类时落在安全侧）；
///   - 段与段之间按原顺序执行，段内并发、结果仍按段内原始顺序交付；
///   - `maxParallel`（配置项 `tool.parallel_max`）为 0 表示不设上限；为正整数时把
///     一个连续的只读段按该值顺次切成多个子并发段，交付顺序不变。
library;

/// 只读工具名（spec「同一轮内连续的只读工具调用并发执行」点名的 9 个）。
///
/// 这个集合是**产品行为**的唯一来源：`planToolGroups` 用它分段，
/// `test/unit/tool_group_planner_test.dart` 用集合相等钉住它，
/// `test/unit/parallel_tools_docs_test.dart` 用它核对用户文档里的名字清单。
const Set<String> kReadOnlyToolNames = <String>{
  'read_file',
  'list_dir',
  'glob_file',
  'grep_file',
  'read_spill',
  'read_image',
  'get_current_time',
  'web_search',
  'web_fetch',
};

/// 逐个执行的有状态工具名（写类、命令、浏览器、子 Agent）。
///
/// 它与 [kReadOnlyToolNames] 一起覆盖工具目录里的全部已知名字：两个集合的并集
/// 必须等于 `ToolCatalog.kBaseToolNames` 加上条件注册的 `web_search` / `web_fetch` /
/// 四个 `browser_*`（共 17 个）。守卫用例按集合相等断言，多一个少一个都红。
const Set<String> kSerialToolNames = <String>{
  'write_file',
  'edit_file',
  'run_command',
  'browser_navigate',
  'browser_click',
  'browser_type',
  'browser_snapshot',
  'spawn_subagent',
};

/// 一个执行段：`[start, end)` 是它在原始调用列表里的下标区间。
class ToolGroupPlan {
  const ToolGroupPlan({
    required this.start,
    required this.end,
    required this.concurrent,
  });

  /// 段内第一个调用的下标（含）。
  final int start;

  /// 段尾下标（不含）。
  final int end;

  /// true = 段内成员并发执行；false = 逐个执行（段长恒为 1）。
  final bool concurrent;

  /// 段内成员数。
  int get length => end - start;

  bool contains(int index) => index >= start && index < end;

  @override
  String toString() =>
      'ToolGroupPlan(start: $start, end: $end, concurrent: $concurrent)';
}

/// 把一轮的工具名序列按原顺序切成最小数量的执行段。
///
/// 纯函数：不读全局状态、不改入参、同样的输入永远得到同样的计划。
///
/// [names] 是模型这一轮发出的工具名顺序；[maxParallel] 是配置项
/// `tool.parallel_max` 的值（0 = 不设上限，正整数 = 单个并发段一次最多同时启动的
/// 成员数）。非法值（负数）按 0 处理 —— 配置解析层已经回落过，这里只做兜底。
List<ToolGroupPlan> planToolGroups(List<String> names, {int maxParallel = 0}) {
  final limit = maxParallel > 0 ? maxParallel : 0;
  final groups = <ToolGroupPlan>[];

  var i = 0;
  while (i < names.length) {
    if (!kReadOnlyToolNames.contains(names[i])) {
      groups.add(ToolGroupPlan(start: i, end: i + 1, concurrent: false));
      i++;
      continue;
    }

    // 连续的只读段：从 i 一直延伸到第一个非只读名字之前。
    var j = i;
    while (j < names.length && kReadOnlyToolNames.contains(names[j])) {
      j++;
    }

    if (j - i == 1) {
      // 段长 1：走原来的逐个路径（单工具时序与并行化之前一致）。
      groups.add(ToolGroupPlan(start: i, end: i + 1, concurrent: false));
    } else if (limit == 0) {
      groups.add(ToolGroupPlan(start: i, end: j, concurrent: true));
    } else {
      for (var s = i; s < j; s += limit) {
        final e = (s + limit < j) ? s + limit : j;
        groups.add(ToolGroupPlan(
          start: s,
          end: e,
          // 切出来的尾巴只剩一个成员时仍按逐个段执行，与"段长 1 走原路"同一条规则。
          concurrent: e - s > 1,
        ));
      }
    }
    i = j;
  }

  return groups;
}
