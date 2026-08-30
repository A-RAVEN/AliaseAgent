import 'dart:convert';

import '../../models/agent_type_config.dart';
import '../../models/message.dart';
import '../provider_resolver.dart';
import '../sidecar_bridge.dart';
import 'compaction_plan.dart';

/// Selects the interior level-1 seams of a far span (design D5 option A:
/// "AI picks the topic seam"). This is the ONLY LLM-assisted point that may move
/// a boundary seam; it is memoized (content-hash keyed) so a rebuild reproduces
/// the same selection and tests stay deterministic.
///
/// Split into an async [ensure] (runs the LLM once, populates the memo) and a
/// synchronous [memoizedSeams] (cold read during the pure buildTree pass). The
/// runtime calls [ensure] BEFORE buildTree, then passes
/// `(far, k) => memoizedSeams(far: far, k: k) ?? const []` as the
/// `L1SeamChooser` — a cold/empty memo simply falls back to the arithmetic-safe
/// skeleton inside buildTree (never splits a tool round, never changes the fold
/// count).
abstract class SeamSelector {
  /// Populate the seam memo for `(far, k)`. Runs the LLM on a cache miss; on any
  /// LLM/parse failure it stores an empty list (so buildTree deterministically
  /// falls back to arithmetic seats) rather than re-calling the model every turn.
  Future<void> ensure({
    required List<Message> far,
    required int k,
    required AgentTypeConfig config,
  });

  /// Synchronously read the memoized seam indices (k-1 interior starts) for
  /// `(far, k)`; null when [ensure] has never run for this exact key.
  List<int>? memoizedSeams({required List<Message> far, required int k});

  /// Count of actual model seam-selection calls made (assert that a rebuild uses
  /// the cache and does NOT re-call the LLM).
  int get llmCallCount;
}

/// The production [SeamSelector]: routes a single seam-selection request through
/// the model gateway on the summary profile (thinking disabled), parsing a
/// `{"seams":[i...]}` JSON list of k-1 safe-candidate indices.
class ModelSeamSelector implements SeamSelector {
  final ISidecar _sidecar;
  final ProviderResolver _resolver;
  final Map<String, List<int>> _memo = {};
  int _llmCalls = 0;

  ModelSeamSelector({
    required ISidecar sidecar,
    required ProviderResolver resolver,
  })  : _sidecar = sidecar,
        _resolver = resolver;

  @override
  int get llmCallCount => _llmCalls;

  /// Content-hash key: the far span's identity (ordinal, role, content) + the
  /// target segment count [k]. Two spans that are textually identical fold to
  /// the same seams.
  static String _key(List<Message> far, int k) {
    final buf = StringBuffer();
    for (var i = 0; i < far.length; i++) {
      final m = far[i];
      buf.write('$i|${m.role}|${m.content.length}:${m.content}|tc=${m.toolCallsJson} ');
    }
    return '${buf.toString().hashCode}|k=$k';
  }

  @override
  List<int>? memoizedSeams({required List<Message> far, required int k}) {
    return _memo[_key(far, k)];
  }

  @override
  Future<void> ensure({
    required List<Message> far,
    required int k,
    required AgentTypeConfig config,
  }) async {
    final key = _key(far, k);
    // Warm memo → no LLM call.
    if (_memo.containsKey(key)) return;

    final provider = _resolver.resolve(config.provider);
    if (provider == null || far.length < 2 || k < 2) {
      _memo[key] = const [];
      return;
    }

    // Safe candidate seams: interior indices (1..far.length-1) at a safe
    // boundary (real user text / terminal assistant with no tool_use — never an
    // assistant carrying tool_calls). The model picks k-1 of these.
    final candidates = <int>[
      for (var i = 1; i < far.length; i++)
        if (CompactionEngine.isSafeBoundary(far[i])) i,
    ];
    if (candidates.length < k - 1) {
      // Not enough safe seams to split into k segments → stay on the skeleton.
      _memo[key] = const [];
      return;
    }

    final count = k - 1;
    final prompt = StringBuffer()
      ..writeln('Choose the topic-seam boundaries for conversation summarization.')
      ..writeln(
          'The span below is being compressed into $k segments, so choose exactly '
          '$count interior boundary positions (message indices within the span) '
          'that split it into $k topically coherent segments.')
      ..writeln('ONLY these indices are SAFE boundaries; pick exactly $count '
          'distinct indices from this list, in increasing order:')
      ..writeln('$candidates')
      ..writeln('Do not reorder, do not choose an index outside the list, do not '
          'invent indices.')
      ..writeln('Return ONLY JSON, e.g. {"seams":[2,7]}.')
      ..writeln('--- span ---');
    for (var i = 0; i < far.length; i++) {
      prompt.writeln('[$i] ${far[i].role.toUpperCase()}: ${far[i].content}');
    }

    final messagesJson = jsonEncode([
      {'role': 'user', 'content': prompt.toString()},
    ]);

    var text = StringBuffer();
    int doneCode = 0;
    try {
      await _sidecar.sendMessage(
        apiKey: provider.apiKey,
        baseUrl: provider.baseUrl,
        model: config.model,
        systemPrompt:
            'You are a conversation summarizer for AliasAgent. Given a span of '
            'messages and a set of safe boundary indices, pick the topic seams.',
        messagesJson: messagesJson,
        toolsJson: '[]',
        thinkingMode: 'summary', // summary profile: thinking disabled, max_tokens 1024
        thinkingEffort: '',
        onChunk: (t) => text.write(t),
        onToolCall: (_) {},
        onDone: (code, err, stop, inTok, outTok) {
          doneCode = code;
        },
      );
      _llmCalls++;
    } catch (_) {
      _memo[key] = const [];
      return;
    }

    if (doneCode != 0) {
      _memo[key] = const []; // LLM failed → deterministic fallback, cache it
      return;
    }

    final seams = _parseSeams(text.toString());
    if (seams == null || seams.length != count || !_isValid(seams, far)) {
      _memo[key] = const []; // unparseable/wrong-count/invalid → fallback skeleton, cache it
      return;
    }
    _memo[key] = seams;
  }

  /// Extract a `{"seams":[...]}` JSON list: the chosen interior seam indices.
  static List<int>? _parseSeams(String text) {
    final start = text.indexOf('{');
    if (start < 0) return null;
    final end = text.indexOf('}', start);
    if (end < 0) return null;
    try {
      final obj = jsonDecode(text.substring(start, end + 1));
      final raw = (obj as Map<String, dynamic>)['seams'];
      if (raw is! List) return null;
      return raw.map((e) => e is num ? e.toInt() : null).whereType<int>().toList();
    } catch (_) {
      return null;
    }
  }

  /// Seam must be strictly increasing, interior, and every chosen index must be a
  /// SAFE boundary (mirrors CompactionEngine._normalizeSeams).
  static bool _isValid(List<int> seams, List<Message> far) {
    var prev = 0;
    for (final s in seams) {
      if (s <= prev || s >= far.length) return false;
      if (!CompactionEngine.isSafeBoundary(far[s])) return false;
      prev = s;
    }
    return true;
  }
}

/// A deterministic [SeamSelector] for hermetic tests: returns a fixed seam list
/// without any I/O, and counts [ensure] calls (for the memo-rebuild test).
class FakeSeamSelector implements SeamSelector {
  final Map<String, List<int>> _memo = {};
  int _ensures = 0;

  /// The seams returned/recorded for every key, when non-null.
  final List<int>? fixedSeams;

  FakeSeamSelector({this.fixedSeams});

  @override
  int get llmCallCount => _ensures;

  @override
  Future<void> ensure({
    required List<Message> far,
    required int k,
    required AgentTypeConfig config,
  }) async {
    final key = ModelSeamSelector._key(far, k);
    // Short-circuit a warm memo so llmCallCount counts CACHE-MISS builds only
    // (interface contract), mirroring ModelSeamSelector.
    if (_memo.containsKey(key)) return;
    _ensures++;
    _memo[key] = fixedSeams ?? const [];
  }

  @override
  List<int>? memoizedSeams({required List<Message> far, required int k}) {
    return _memo[ModelSeamSelector._key(far, k)];
  }
}
