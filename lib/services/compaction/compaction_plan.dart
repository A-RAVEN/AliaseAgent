import '../../models/message.dart';
import '../context_estimator.dart';

/// One unit of the compacted conversation: either a segment to be folded into a
/// level-1 summary, or a verbatim (near) segment replayed via _buildApiMessages.
///
/// Segments are always atomic-safe: buildTree only ever cuts between persisted
/// Messages, and a persisted assistant message carrying tool_calls IS a complete
/// tool round (its derived synthetic user(tool_result) is emitted from that same
/// Message by _buildApiMessages), so a segment boundary can never split a
/// tool_use/tool_result pair.
class CompactionSegment {
  final List<Message> messages; // oldest → newest within the segment
  final bool summary; // true → folded to a level-1 summary; false → verbatim
  const CompactionSegment({required this.messages, required this.summary});
}

/// The deterministic fold plan (decision/execution separation).
///
/// buildTree is a pure function of (history, budget): it decides WHICH segments
/// fold into summaries and which stay verbatim, plus the projected token count.
/// It does NOT call the model — the model fills the content of the already-chosen
/// summary leaves. This determinism lets tests assert tree shape without wording.
class CompactionPlan {
  /// Segments, oldest → newest. Near (verbatim) segments are at the end.
  final List<CompactionSegment> segments;

  /// Projected token count of the compacted projection (summaries + verbatim).
  final int projectedTokens;

  /// True when a fold is required (at least one summary segment).
  final bool shouldCompact;

  const CompactionPlan({
    required this.segments,
    required this.projectedTokens,
    required this.shouldCompact,
  });

  bool get hasSummary => segments.any((s) => s.summary);

  /// Messages kept verbatim (near), oldest → newest (flattened).
  List<Message> get verbatim =>
      segments.where((s) => !s.summary).expand((s) => s.messages).toList();

  /// Messages folded into summaries (far), oldest → newest (flattened).
  List<Message> get folded =>
      segments.where((s) => s.summary).expand((s) => s.messages).toList();
}

/// Pure, deterministic compaction decision logic.
///
/// Two-level recency gradient (design knob B): near messages kept verbatim,
/// medium-distance messages folded into per-segment (level-1) summaries. The
/// gradient is a pure function of segment index + config. Phase 1 reduced to a
/// single root summary; this generalizes to multiple level-1 segments.
class CompactionEngine {
  /// Conservative proxy overhead per summary (marker + structural).
  static const int _summaryOverhead = 24;

  /// Empirical compression ratio proxy: a level-1 summary is ~1/~4 the tokens
  /// of the content it replaces (pure, deterministic).
  static const int _summaryCompressionFactor = 4;

  /// Number of messages per level-1 summary segment.
  static const int _segmentSize = 8;

  /// Build the fold plan for a conversation.
  static CompactionPlan buildTree({
    required List<Message> history,
    required int maxContextTokens,
  }) {
    final totalProxy = ContextEstimator.estimateConversation(history);
    if (totalProxy <= maxContextTokens) {
      return CompactionPlan(
        segments: [CompactionSegment(messages: List.of(history), summary: false)],
        projectedTokens: totalProxy,
        shouldCompact: false,
      );
    }

    // Choose foldEnd = index of the first near-verbatim message. Messages
    // [0..foldEnd) are summarizable; [foldEnd..] are verbatim. Grow verbatim
    // greedily from the newest message while the (budget-coarsened) summary cost
    // of the far span still fits the budget.
    var foldEnd = history.length;
    var verbatimCost = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      final mCost = ContextEstimator.estimateMessage(history[i]);
      final summaryCost = _coarsenedSummaryCost(history.sublist(0, i), maxContextTokens);
      if (verbatimCost + mCost + summaryCost <= maxContextTokens) {
        verbatimCost += mCost;
        foldEnd = i;
      } else {
        break;
      }
    }

    // Safe-boundary alignment: the near span must start on a SAFE cut point per
    // the spec — a real user text message, or a terminal assistant message with
    // no tool_use, NEVER on an assistant message carrying tool_calls (would cut
    // a tool round). Never advance past the newest message.
    //
    // Index 0 is the conversation-START segment edge, not a boundary between two
    // segments, so it is exempt: the user always sends the first message (a real
    // user text) and a between-message boundary can never split a tool round
    // because the tool_result is synthesized from the same assistant message by
    // _buildApiMessages. Interior far-span chunk starts ARE snapped safe inside
    // _budgetSegments.
    foldEnd = _alignToSafeBoundary(history, foldEnd);

    final far = history.sublist(0, foldEnd);
    final near = history.sublist(foldEnd);
    final segments = <CompactionSegment>[
      ..._budgetSegments(far, maxContextTokens), // each far chunk -> a summary segment
      if (near.isNotEmpty) CompactionSegment(messages: near, summary: false),
    ];
    final projected = _summariesCost(segments.where((s) => s.summary).toList()) +
        CompactionEngine._verbatimCost(near);
    return CompactionPlan(
      segments: segments,
      projectedTokens: projected,
      shouldCompact: segments.any((s) => s.summary),
    );
  }

  /// The coarsened summary cost of a far span — the cheapest way to fold it.
  /// Decrease the segment count until the split fits the budget (coarsen-only).
  static int _coarsenedSummaryCost(List<Message> far, int budget) {
    final k = _maxSegmentsForBudget(far, budget);
    return _summaryCostWithK(far, k);
  }

  /// Largest segment count (≤ base granularity) whose split of [far] fits
  /// [budget]. Returns ≥1 (never 0).
  static int _maxSegmentsForBudget(List<Message> far, int budget) {
    if (far.isEmpty) return 1;
    final base = (far.length + _segmentSize - 1) ~/ _segmentSize;
    var k = base < 1 ? 1 : base;
    while (k > 1 && _summaryCostWithK(far, k) > budget) {
      k--;
    }
    return k;
  }

  /// Cost of splitting [far] into [k] roughly-equal summary chunks.
  static int _summaryCostWithK(List<Message> far, int k) {
    if (far.isEmpty) return 0;
    if (k <= 1) {
      final proxy = ContextEstimator.estimateConversation(far);
      return (proxy ~/ _summaryCompressionFactor) + _summaryOverhead;
    }
    final chunkSize = (far.length + k - 1) ~/ k;
    var cost = 0;
    for (var start = 0; start < far.length; start += chunkSize) {
      final end = (start + chunkSize) > far.length ? far.length : start + chunkSize;
      final chunk = far.sublist(start, end);
      if (chunk.isEmpty) continue;
      final proxy = ContextEstimator.estimateConversation(chunk);
      cost += (proxy ~/ _summaryCompressionFactor) + _summaryOverhead;
    }
    return cost;
  }

  /// Split a far span into budget-coarsened level-1 summary segments.
  ///
  /// Every interior chunk boundary is snapped to a SAFE segment boundary (spec
  /// "Safe segment boundary choice" / D6 "never cut mid-tool"): a summary chunk
  /// must never BEGIN on an assistant message carrying tool_calls — only on a
  /// real user text message or a terminal assistant with no tool_use. Snapping
  /// forward never drops messages: the absorbed (unsafe) messages stay in the
  /// preceding chunk, so the segment count can only shrink (coarser => still
  /// under budget), never split a tool round.
  static List<CompactionSegment> _budgetSegments(List<Message> far, int budget) {
    if (far.isEmpty) return [];
    final k = _maxSegmentsForBudget(far, budget);
    final chunkSize = (far.length + k - 1) ~/ k;
    // Desired interior boundaries (0 and far.length are implicit chunk edges).
    final starts = <int>[];
    for (var s = chunkSize; s < far.length; s += chunkSize) {
      var snapped = s;
      while (snapped < far.length && !_isSafeBoundary(far[snapped])) {
        snapped++;
      }
      if (snapped < far.length && (starts.isEmpty || snapped > starts.last)) {
        starts.add(snapped);
      }
    }
    // Build chunk segments from the snapped boundaries; unsafe messages absorbed
    // by the preceding chunk (boundary--never-cuts-mid-tool).
    final segments = <CompactionSegment>[];
    var start = 0;
    for (final boundary in starts) {
      if (boundary > start) {
        segments.add(CompactionSegment(messages: far.sublist(start, boundary), summary: true));
        start = boundary;
      }
    }
    if (start < far.length) {
      segments.add(CompactionSegment(messages: far.sublist(start), summary: true));
    }
    return segments;
  }

  /// Advance [foldEnd] to a SAFE segment boundary (spec "Safe segment boundary
  /// choice"): a real user text message, or a terminal assistant message with no
  /// tool_use — never on an assistant message carrying tool_calls. Clamped so the
  /// newest message is never dropped (foldEnd never exceeds length-1).
  static int _alignToSafeBoundary(List<Message> history, int foldEnd) {
    while (foldEnd < history.length - 1 && !_isSafeBoundary(history[foldEnd])) {
      foldEnd++;
    }
    if (foldEnd > history.length) foldEnd = history.length;
    return foldEnd;
  }

  /// True when the message at [m] is a legal segment boundary: real user text, or
  /// a terminal assistant with no tool_use. Never an assistant carrying tool_calls.
  static bool _isSafeBoundary(Message m) {
    if (m.role == 'user') return true;
    if (m.role == 'assistant') {
      return m.toolCallsJson == null || m.toolCallsJson!.isEmpty;
    }
    return false;
  }

  /// Proxy token cost of a set of summary segments.
  static int _summariesCost(List<CompactionSegment> summaries) {
    var cost = 0;
    for (final s in summaries) {
      if (s.messages.isEmpty) continue;
      final proxy = ContextEstimator.estimateConversation(s.messages);
      cost += (proxy ~/ _summaryCompressionFactor) + _summaryOverhead;
    }
    return cost;
  }

  /// Sum of per-message proxy cost of a verbatim span.
  static int _verbatimCost(List<Message> verbatim) {
    var cost = 0;
    for (final m in verbatim) {
      cost += ContextEstimator.estimateMessage(m);
    }
    return cost;
  }
}
