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
  final bool summary; // true → folded to a summary; false → verbatim
  final int level; // 1 = level-1 segment summary, 2 = level-2 summary-of-summaries, 0 = verbatim
  final ClosedSummary? reuse; // non-null → this (closed) segment reuses a cached summary
  final List<List<int>>? l2SubSpans; // level-2 only: each [startSeq, endSeq] of a
                                     // level-1 sub-span, for 2-pass "summary of summaries".
  const CompactionSegment({
    required this.messages,
    required this.summary,
    this.level = 1,
    this.reuse,
    this.l2SubSpans,
  });

  bool get isClosed => reuse != null;
}

/// A conversation segment already delimited by two cut markers — FIXED history
/// (progressive closure). Its content and summary never change: the reuse-gate
/// MUST always cache-hit it and never re-summarize it. Persisted in
/// `summary_nodes`, keyed by its covered (start_seq, end_seq) span.
class ClosedSummary {
  final int level; // 1 = level-1 summary, 2 = level-2 summary (for cache lookup)
  final int coveredMinSeq;
  final int coveredMaxSeq;
  final int tokenCost; // proxy cost of the cached summary token (budget accounting)
  const ClosedSummary({
    required this.level,
    required this.coveredMinSeq,
    required this.coveredMaxSeq,
    required this.tokenCost,
  });
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
  ///
  /// Progressive closure (D8): the passed-in [closed] segments are FROZEN fixed
  /// history — their summaries are reused verbatim, never re-folded or re-shaped.
  /// Only the unclosed TAIL (messages newer than the newest closed segment) is a
  /// candidate for new folding. So this is a pure function of
  /// (history, budget, closed-segmentation): deterministic given those inputs.
  static CompactionPlan buildTree({
    required List<Message> history,
    required int maxContextTokens,
    List<ClosedSummary> closed = const [],
  }) {
    final closedFloor = closed.isEmpty
        ? -1
        : closed.map((c) => c.coveredMaxSeq).reduce((a, b) => a > b ? a : b);
    final frozenCost = closed.fold(0, (m, c) => m + c.tokenCost);

    var tailStart = 0;
    while (tailStart < history.length &&
        (history[tailStart].seq ?? 0) <= closedFloor) {
      tailStart++;
    }
    final tail = history.sublist(tailStart);
    final tailBudget = (maxContextTokens - frozenCost) < 0 ? 0 : maxContextTokens - frozenCost;

    final closedSegments = <CompactionSegment>[
      for (final c in closed)
        CompactionSegment(
          messages: _spanMessages(history, c.coveredMinSeq, c.coveredMaxSeq),
          summary: true,
          level: c.level, // preserve the closed segment's level (L1 or L2)
          reuse: c,
        ),
    ];
    final tailPlan = _foldTail(tail, tailBudget);
    return CompactionPlan(
      segments: [
        ...closedSegments,
        ...tailPlan.segments,
      ],
      projectedTokens: frozenCost + tailPlan.projectedTokens,
      shouldCompact: closedSegments.isNotEmpty || tailPlan.shouldCompact,
    );
  }

  /// Messages of [history] whose seq lies in [minSeq..maxSeq] (oldest → newest).
  static List<Message> _spanMessages(List<Message> history, int minSeq, int maxSeq) {
    return history.where((m) {
      final s = m.seq ?? 0;
      return s >= minSeq && s <= maxSeq;
    }).toList();
  }

  /// Fold plan for the not-yet-closed tail: far span folded into level-1 (or
  /// level-2 via [CompactionEngine] callers) summaries, near span kept verbatim.
  static CompactionPlan _foldTail(List<Message> messages, int budget) {
    if (messages.isEmpty) {
      return const CompactionPlan(
          segments: [], projectedTokens: 0, shouldCompact: false);
    }
    final totalProxy = ContextEstimator.estimateConversation(messages);
    if (totalProxy <= budget) {
      return CompactionPlan(
        segments: [CompactionSegment(messages: List.of(messages), summary: false)],
        projectedTokens: totalProxy,
        shouldCompact: false,
      );
    }

    // Choose foldEnd = index of the first near-verbatim message. Messages
    // [0..foldEnd) are summarizable; [foldEnd..] are verbatim. Grow verbatim
    // greedily from the newest message while the (budget-coarsened) summary cost
    // of the far span still fits the budget.
    var foldEnd = messages.length;
    var verbatimCost = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final mCost = ContextEstimator.estimateMessage(messages[i]);
      final summaryCost = _coarsenedSummaryCost(messages.sublist(0, i), budget);
      if (verbatimCost + mCost + summaryCost <= budget) {
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
    foldEnd = _alignToSafeBoundary(messages, foldEnd);

    final far = messages.sublist(0, foldEnd);
    final near = messages.sublist(foldEnd);
    final farBudget = budget - verbatimCost;

    // Gradient (4.2, canonical-cover front): far span = [L2 最旧][L1 中段].
    // The L1 segmentation is the deterministic skeleton (_budgetSegments, see
    // task 4.3 for the AI-seam refinement); L2 grouping is arithmetic + coarsen-
    // only. Then append the near-verbatim span.
    final l1s = _budgetSegments(far, budget);
    final gradient = _buildGradient(l1s, farBudget);
    var segments = <CompactionSegment>[
      ...gradient,
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

  /// Coarsen-only gradient over the level-1 summary segments of a far span:
  /// keep the NEWEST level-1s as level-1 (medium tier), roll the OLDEST level-1s
  /// into ONE level-2 "summary of summaries" (deep tier). Merges more oldest
  /// L1s into the level-2 as the budget tightens (coarsen-only — never splits).
  /// If a lone level-2 over the whole far still exceeds [farBudget], OMIT the
  /// OLDEST content from the projection (data is NOT deleted — see spec
  /// "Original conversation retained on disk"). Returns [L2][L1...] (newest last).
  static List<CompactionSegment> _buildGradient(
      List<CompactionSegment> l1s, int farBudget) {
    if (l1s.isEmpty) return [];
    // If the level-1 segmentation already fits (incl. a single L1), keep it —
    // the L1 tier is the medium/preferred granularity.
    if (_summariesCost(l1s) <= farBudget) return l1s;

    // Coarsen-only: merge the OLDEST L1(s) into a growing level-2 group until
    // [l2 + remaining L1s] fits. Record the merged L1 sub-spans so the level-2
    // can be generated as a 2-pass "summary of summaries".
    var l2Msgs = <Message>[];
    final merged = <CompactionSegment>[];
    var rest = List<CompactionSegment>.of(l1s);
    while (rest.isNotEmpty) {
      l2Msgs = [...l2Msgs, ...rest.first.messages];
      merged.add(rest.first);
      rest = rest.sublist(1);
      final l2Cost = CompactionEngine._summaryCostWithK(l2Msgs, 1);
      if (l2Cost + _summariesCost(rest) <= farBudget) {
        return [
          CompactionSegment(messages: l2Msgs, summary: true, level: 2,
              l2SubSpans: merged.map(_spanOf).toList()),
          ...rest,
        ];
      }
    }

    // A lone level-2 over the whole far is the coarsest; if it still exceeds the
    // budget, OMIT the OLDEST content (projection only — data kept on disk).
    if (CompactionEngine._summaryCostWithK(l2Msgs, 1) <= farBudget) {
      return [
        CompactionSegment(messages: l2Msgs, summary: true, level: 2,
            l2SubSpans: merged.map(_spanOf).toList()),
      ];
    }
    // Truncated (omit) case: sub-spans are lost, so the level-2 resolves as a
    // single coarser (1-pass) summary — a null l2SubSpans means 1-pass.
    var kept = List<Message>.of(l2Msgs);
    while (kept.isNotEmpty && CompactionEngine._summaryCostWithK(kept, 1) > farBudget) {
      kept.removeAt(0);
    }
    if (kept.isEmpty) return [];
    return [CompactionSegment(messages: kept, summary: true, level: 2)];
  }

  /// [startSeq, endSeq] span of a segment's messages (for L2 sub-span recording).
  static List<int> _spanOf(CompactionSegment s) {
    if (s.messages.isEmpty) return [0, 0];
    return [(s.messages.first.seq ?? 0), (s.messages.last.seq ?? 0)];
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
