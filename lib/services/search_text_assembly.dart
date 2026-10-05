/// 把 `web_search` 的多后端结果拼成**给模型看的那段正文**。
///
/// 为什么单独一个文件：这段拼装必须能被单元测试直接调用（要能传一个很小的预算，
/// 逼出"有后端被省略"那一支）。放在 `main.dart` 里的私有方法在别的库里读不到，
/// 测试只能绕道界面走完整链路 —— 那样"省略分支"根本构造不出来。
///
/// 两条硬规矩（`openspec/changes/fix-silent-truncation`）：
///   1. **每个后端先无条件写自己的结果行**（`<名字>: <条数> results`，出错写
///      `ERROR — …`）—— 这是结构性信息，一行几十字，不许被预算吃掉；预算只允许
///      压缩各自的**预览细节**；
///   2. 被省略的内容必须**点名**（哪些后端、各多少条），不许只说"还有 N 个没显示"。
library;

/// 这道通用截断阈值只留这一份定义：界面里 `lib/main.dart` 的
/// `kToolResultElisionThreshold` 直接取它（`= searchTextElisionThreshold`），
/// 搜索结果拼装也用它当默认预算 —— "拼装预算 ≤ 通用截断阈值"于是结构上不可能漂移。
const int searchTextElisionThreshold = 8000;

/// 拼装时用的默认预算 = [searchTextElisionThreshold]。
int get defaultSearchTextBudget => searchTextElisionThreshold;

/// 拼 `web_search` 的结果给模型看。
///
/// - [result] 是 sidecar 返回的那一整包（含 `results: {后端名: {results: [...]}}`）；
/// - [budget] 是这段文本的字符预算，缺省 [searchTextElisionThreshold]；测试会传一个
///   小值来逼出"预览被省略"的分支。
String assembleSearchText(Map<String, dynamic> result, {int? budget}) {
  final results = result['results'] as Map<String, dynamic>?;
  if (results == null || results.isEmpty) {
    return 'No results found.';
  }

  final maxLen = budget ?? searchTextElisionThreshold;

  // ---- 第一遍：每个后端的结果行，一律写出来 ----
  final lines = <String>[];
  final orderedNames = <String>[];
  var totalLen = 0;
  for (final ns in results.keys) {
    final nsData = results[ns] as Map<String, dynamic>?;
    if (nsData == null) continue;
    orderedNames.add(ns.toString());
    final String line;
    if (nsData.containsKey('error')) {
      final err = (nsData['error'] as String?) ?? 'Unknown error';
      line = '$ns: ERROR — ${err.length > 200 ? '${err.substring(0, 200)}...' : err}';
    } else {
      final items = nsData['results'] as List<dynamic>?;
      line = '$ns: ${items?.length ?? 0} results';
    }
    lines.add(line);
    totalLen += line.length + 1;
  }
  if (lines.isEmpty) return 'No results found.';

  // ---- 第二遍：剩余预算按后端数量均分给各自的首条预览 ----
  final remaining = maxLen - totalLen;
  final share = remaining > 0 ? remaining ~/ orderedNames.length : 0;
  final previews = <String, String>{};
  final omitted = <String>[];
  for (final ns in orderedNames) {
    final nsData = results[ns] as Map<String, dynamic>?;
    if (nsData == null || nsData.containsKey('error')) continue;
    final items = nsData['results'] as List<dynamic>?;
    if (items == null || items.isEmpty) continue;
    final first = items[0] as Map<String, dynamic>?;
    if (first == null) continue;
    final title = (first['title'] as String?) ?? '';
    final url = (first['url'] as String?) ?? '';
    final content = (first['content'] as String?) ?? '';
    var preview = '';
    if (title.isNotEmpty) preview += title;
    if (url.isNotEmpty) {
      if (preview.isNotEmpty) preview += ' — ';
      preview += url;
    }
    // 空间够就再带一段正文；不够就只留"标题 — 网址"。
    final room = share - preview.length - 1;
    if (content.isNotEmpty && room > 20) {
      preview += '\n${content.length > room ? '${content.substring(0, room)}...' : content}';
    }
    if (preview.isEmpty) continue;
    // 连"标题 — 网址"都放不下：不写预览，但必须留下说明（不许静默）。
    if (share <= 0 || preview.length > share) {
      omitted.add(ns);
      continue;
    }
    previews[ns] = preview;
  }

  // ---- 拼装：结果行 + 各自的预览；省略一律点名 ----
  final buf = StringBuffer();
  for (final line in lines) {
    buf.writeln(line);
    final ns = line.split(':').first;
    final preview = previews[ns];
    if (preview != null) {
      buf.writeln(preview);
    } else if (omitted.contains(ns)) {
      buf.writeln('（本条预览因篇幅未显示，结果条数见上面一行）');
    }
  }
  if (omitted.isNotEmpty) {
    final parts = omitted.map((ns) {
      final nsData = results[ns] as Map<String, dynamic>?;
      final items = nsData?['results'] as List<dynamic>?;
      final count = items?.length ?? 0;
      return '$ns（$count 条）';
    }).join('、');
    buf.writeln('... 以下后端只给出了条数、没给出预览：$parts');
  }
  return buf.toString().trimRight();
}
