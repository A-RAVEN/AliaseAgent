import 'dart:convert';

import 'package:alias_agent/models/message.dart';

/// A-1 fixture: a realistic AliasAgent config-refactor conversation.
///
/// Load-bearing re-execution keys that A-2 asserts the real summary preserves:
/// - [kConfigPath] — absolute path (a re-execution key / tool_input path)
/// - [kDecisionOld] / [kDecisionNew] — the decision (timeout 120 → 30)
/// - [kDecisionKeyword] — the config field being changed (`timeout`)
///
/// The fixture is hand-authored (not downloaded / not a novel); it mirrors this
/// app's real tool round shape (assistant tool_calls + derived synthetic
/// user(tool_result), which _buildApiMessages synthesizes) so the summarizer sees
/// a faithful AliasAgent-style transcript. The user goal + hard invariant
/// (`don't touch email`) are present as content for realism but [kInvariantTag]
/// is NOT asserted in the summary — per spec.md:36 the invariant never reaches a
/// summary (it is re-injected by the standing-requirements guard layer), so A-2
/// only asserts the re-execution keys.
const String kConfigPath = '/Users/acme/src/config.dart';
const String kDecisionOld = '120';
const String kDecisionNew = '30';
const String kDecisionKeyword = 'timeout';
/// A soft marker for the invariant so the fixture text is self-consistent; A-2
/// deliberately does NOT assert it appears in the summary (guard layer's job).
const String kInvariantTag = 'email';

/// Realistic code-session exchange template pool. Each entry = (user, assistant).
/// Cycle with a turn index so content is unique in a way the model must NOT
/// collapse, and stays on-theme (a long config-refactor working session) so an
/// L1/L2 summary is meaningful rather than filler gibberish.
const List<(String, String)> _fillerPool = [
  ('检查一下 validate 函数的边界条件。',
      '我核对了 validate 的边界：空输入、全空格和超长字符串都能正确返回校验失败，未发现越界访问。'),
  ('这段排序算法稳定吗？',
      '当前用的是归并排序，属于稳定排序，相等元素顺序保持原样。切到不稳定排序会影响下游结果。'),
  ('给这个模块补一个单元测试。',
      '已为 config 解析模块补充了覆盖正常输入、缺失字段和非法值三个分支的单元测试。'),
  ('启动日志里有个警告，帮我排查。',
      '该警告来自 config 模块里一个未使用的导入。清理后重新构建，告警消失。'),
  ('把超时相关的常量提取成一个枚举吧。',
      '已将 timeout 相关常量收敛为 ConfigTimeout 枚举，集中定义，避免魔法数字散落。'),
  ('这个函数拆分一下，太长了。',
      '已把 parseConfig 拆为 parseSchema 和 validateValues 两个小函数，职责各自单一。'),
  ('补一下代码注释，说明为什么这里要重试。',
      '已为重试逻辑补充注释：网络抖动时重试两次、间隔递增，提升瞬时失败容错。'),
  ('检查有没有把日志打到生产环境。',
      '检查了所有 debugPrint 调用，均带 DEBUG 隔离，生产构建不会输出调试日志。'),
  ('这个配置项要不要做向后兼容？',
      '已加兼容分支：新版字段优先、旧字段作为回退，同时写入迁移告警日志。'),
  ('把读取文件的错误处理统一一下。',
      '已将三处 read_file 的错误处理汇总为一个统一的 Result 包装，异常信息不再散落。'),
  ('这版改动会影响其他模块吗？',
      '做了影响面扫描：改动局限在 config 与 http 两个模块，其余模块共享的接口未变。'),
  ('把默认配置和示例配置同步一下。',
      '已同步 config.example 与默认值，并补充注释说明二者必须保持一致的约束。'),
  ('确认一下编码格式是 UTF-8。',
      '已确认源文件统一 UTF-8 且带换行，git 配置也禁止跨平台行尾自动转换。'),
  ('这个依赖要不要锁版本。',
      '已在 pubspec 锁定该依赖版本，避免上游破坏性更新影响当前行为。'),
];

/// Build the foldable-keys conversation for A-1/A-2.
///
/// The load-bearing keys live in the OLDEST messages so that — under a fold with
/// a modest budget — they fall in the far (folded) span, while the newest bounded
/// verbatim chunk (≤ T = budget~/2) carries only the newest filler + the current
/// user message. This satisfies A-1 constraint ① (keys in the foldable band, not
/// the newest-verbatim chunk, not omit-oldest) so a coverage assertion is
/// meaningful rather than relying on luck.
///
/// [fillerTurns] sizes the far span. A compaction-worthy far span must be large
/// enough that a real summary is a genuine COMPRESSION (measured output tokens <
/// the raw batch) — a tiny far span would give the model only a few hundred chars
/// to summarize, and a verbose structured model would EXPAND it (summary.tokens >
/// raw), which per design D3/D4 is a bloat that would be split/omitted rather
/// than sent. This fixture therefore generates many turns so the far band is a
/// real compression target. Returns messages with strictly increasing `seq`;
/// caller appends the current user message as the newest.
List<Message> buildConfigRefactorConversation({int fillerTurns = 40, String sessionId = 's1'}) {
  final sid = sessionId;
  final msgs = <Message>[];
  var seq = 1;
  Message add(String role, String content, {String? toolCallsJson}) {
    final m = Message(
      id: 'm$seq',
      seq: seq,
      sessionId: sid,
      role: role,
      content: content,
      toolCallsJson: toolCallsJson,
      createdAt: seq,
    );
    seq++;
    msgs.add(m);
    return m;
  }

  // --- foldable (oldest), load-bearing ---
  add('user',
      '我需要重构这个项目的配置。请先读取 $kConfigPath，分析怎么把连接超时从 '
      '$kDecisionOld 秒改为 $kDecisionNew 秒，这是我这次会话最关键的改动。');
  add('assistant', '',
      toolCallsJson: jsonEncode([
        {
          'id': 'call_read_config',
          'toolName': 'read_file',
          'name': 'read_file',
          'input': {'path': kConfigPath},
          'result':
              '// connection timeout (seconds)\nconst timeout = $kDecisionOld;\napi.timeout = $kDecisionOld;',
        }
      ]));
  add('assistant',
      '已经读取 $kConfigPath。当前连接超时是 $kDecisionOld 秒（timeout=$kDecisionOld）。'
      '我会把它改为 $kDecisionNew 秒，并且绝不碰 $kInvariantTag 相关配置。');
  add('user', '好，那除了把 timeout 改成 $kDecisionNew，其他配置项都保留。');
  add('assistant',
      '明白，只改 timeout（$kDecisionOld->$kDecisionNew），$kInvariantTag 部分完全保持原样。');

  // --- filler tail (newer). Cycles the template pool so the far span grows into a
  // realiztic, meaningful long working session (the keys stay oldest/folded). ---
  for (var i = 0; i < fillerTurns; i++) {
    final (u, a) = _fillerPool[i % _fillerPool.length];
    add('user', '（第${i + 1}轮）$u');
    add('assistant', '（第${i + 1}轮）$a');
  }

  return msgs;
}
