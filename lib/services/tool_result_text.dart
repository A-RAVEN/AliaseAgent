import '../models/tool_call_activity.dart';
import 'search_text_assembly.dart';

/// 工具结果正文的拼装与截断（从 `lib/main.dart` 的 `ChatScreenState` 静态方法搬出）。
///
/// 为什么单独一个服务文件：Agent 执行工具时必须用**同一套**拼装规则，而界面还要
/// 能读这些常量与纯函数。放进 `main.dart` 会让"执行对象"反过来依赖界面状态文件，
/// 也让纯函数无法被单元测试直接调用。`ChatScreenState` 保留下来的同名静态成员只是
/// 转发到这里，测试的调用点不变。

/// 通用截断阈值：只留这一份定义（与搜索结果拼装共用同一个常量）。
const int kToolResultElisionThreshold = searchTextElisionThreshold;

/// spill 引用行在模型可见正文里的固定标记。**只在这里写一次**：
/// [composeCommandResultText] 拼它、[bodyHasSpillRefs] 认它，两处一改就一起坏。
const String kSpillRefsMarker = '[spill refs:';

/// 这段正文里有没有 spill 引用（决定通用截断的尾注该说什么）。
bool bodyHasSpillRefs(String body) => body.contains(kSpillRefsMarker);

/// `run_command` 的**模型可见正文**：标准输出、可选的 `[stderr]` 段、spill 引用
/// 一行、超时与退出码标记。
///
/// 顺序有讲究：**引用必须放在最后一行** —— 通用截断只保留头尾两段，放中间等于被
/// 自己掐掉。
String composeCommandResultText(Map<String, dynamic> parsed) {
  final sb = StringBuffer();
  final outText = (parsed['stdout'] as String?) ?? '';
  final errText = (parsed['stderr'] as String?) ?? '';
  if (outText.trim().isEmpty && errText.trim().isEmpty) {
    sb.writeln('(no output)');
  } else {
    if (outText.isNotEmpty) {
      sb.write(outText.endsWith('\n') ? outText : '$outText\n');
    }
    if (errText.isNotEmpty) {
      sb.writeln('[stderr]');
      sb.write(errText.endsWith('\n') ? errText : '$errText\n');
    }
  }
  // spill 引用与省略量：**永远放在最后**，这样通用截断（保头保尾）掐不到它。
  final spill = parsed['spill'];
  if (spill is Map) {
    final parts = <String>[];
    for (final entry in spill.entries) {
      final env = entry.value;
      if (env is! Map) continue;
      final ref = (env['ref'] as String?) ?? '';
      if (ref.isEmpty) continue;
      final total = env['total_bytes'] ?? 0;
      final omitted = env['omitted_bytes'] ?? 0;
      parts.add('${entry.key}=$ref ($total bytes, $omitted omitted)');
    }
    if (parts.isNotEmpty) {
      sb.writeln('$kSpillRefsMarker ${parts.join('; ')} — read any byte range back '
          'with read_spill(ref, offset, limit)]');
    }
  }
  if (parsed['timed_out'] == true) {
    sb.writeln('[timed out after ${(parsed['duration_ms'] ?? 0)}ms]');
  }
  final exitCode = parsed['exit_code'];
  if (exitCode is int && exitCode != 0) {
    sb.writeln('[exit code: $exitCode]');
  }
  return sb.toString().trimRight();
}

/// Elide an oversized tool_result BODY (near-zone elision). Keeps a head/tail
/// preview (~the threshold total) + a truncation marker recording the original
/// byte length + the refetch path, so the round stays a valid tool_use/
/// tool_result pair and the full body is recoverable via the tool + path.
String elideOversizedToolResult({
  required String name,
  required String path,
  required String body,
}) {
  if (body.length <= kToolResultElisionThreshold) return body;
  final half = kToolResultElisionThreshold ~/ 2;
  final head = body.substring(0, half);
  final tail = body.substring(body.length - half);
  final hasSpillRef = bodyHasSpillRefs(body);
  final refetch = path.isNotEmpty
      ? '; refetch via $name "$path"'
      : (hasSpillRef
          ? '; 中间的原文可用 read_spill(ref, offset, limit) 读回（ref 见上面那行 spill refs）'
          : '; 本篇无法自动再取，请重新给出地址后再试');
  return '$head\n...[truncated middle of ${body.length - 2 * half} chars]...\n$tail'
      '\n[tool_result body elided: ${body.length} chars > threshold '
      '$kToolResultElisionThreshold$refetch]';
}

/// `edit_file` 模型可见文本的尾巴：`— 第 12、40 行`。
///
/// 行号清单本身也受 [kToolResultElisionThreshold] 约束：超过它时只列前几条，
/// 并写明共几处、其余去哪看——砍内容必须可见、可见之后必须可取回。
String editLineSuffix(List<dynamic> hunks) {
  final lines = <int>[];
  for (final hunk in hunks) {
    if (hunk is! Map) continue;
    final line = (hunk['start_line'] as num?)?.toInt();
    if (line != null && line > 0 && !lines.contains(line)) lines.add(line);
  }
  if (lines.isEmpty) return '';
  final full = ' — 第 ${lines.join('、')} 行';
  if (full.length <= kToolResultElisionThreshold) return full;
  final note = ' — 共 ${lines.length} 处改动，其余行号见卡片';
  final budget = kToolResultElisionThreshold - note.length - ' — 第  行'.length;
  final shown = <int>[];
  var used = 0;
  for (final line in lines) {
    final added = (shown.isEmpty ? 0 : 1) + '$line'.length;
    if (used + added > budget) break;
    shown.add(line);
    used += added;
  }
  if (shown.isEmpty) return note;
  return ' — 第 ${shown.join('、')} 行$note';
}

/// 把 sidecar 返回的 hunks 转成活动对象用的形态；不可用时给 null。
List<EditHunk>? parseEditHunks(Object? raw) {
  if (raw is! List || raw.isEmpty) return null;
  final hunks = <EditHunk>[];
  for (final item in raw) {
    if (item is! Map) continue;
    final line = (item['start_line'] as num?)?.toInt();
    final oldText = item['old_text'];
    final newText = item['new_text'];
    if (line == null || oldText is! String || newText is! String) continue;
    hunks.add(EditHunk(startLine: line, oldText: oldText, newText: newText));
  }
  return hunks.isEmpty ? null : hunks;
}
