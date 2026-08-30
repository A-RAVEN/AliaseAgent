import '../../models/message.dart';
import '../context_estimator.dart';

/// Chooses the interior level-1 seams of a far span (design D5 option A).
///
/// Given the far span (messages to be folded) and the target level-1 segment
/// count [k] (already fixed by the pure/arithmetic skeleton), return the [k]-1
/// 0-based indices into [far] that START each segment after the first; e.g. for
/// far = [...] and k = 3, `[4, 9]` splits far into `[0..4)[4..9)[9..len)`.
///
/// This is the ONLY LLM-assisted bit that may move the boundary seam. It must
/// never change WHICH messages fold, how many segments there are, the budget, or
/// the cover topology — the skeleton fixes those. Return a list that fails
/// safety/strictness/count validation and the pipeline falls back to the
/// arithmetic-safe skeleton (so a misbehaving seam can never split a tool round).
///
/// The chooser is expected to be deterministic: production feeds a memoized LLM
/// result (content-hash keyed) so rebuild/tests are reproducible; hermetic tests
/// inject a fixed chooser.
typedef L1SeamChooser = List<int> Function(List<Message> far, int k);

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
  /// Batch threshold (design D3/D4): a batch is cut when its accumulated RAW
  /// proxy token total exceeds `T = maxContextTokens ~/ 2`. Half the budget is a
  /// structural, tunable knob ("doesn't need to be precise"); boundaries are
  /// pure/deterministic (raw tokens are additive). No compression-ratio assumed
  /// (no `/4`) — a summary's size is only known after the summarization call and
  /// SHALL be measured at runtime ([_foldTail] only fixes batch boundaries).
  static int _batchThreshold(int maxContextTokens) => maxContextTokens ~/ 2;

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
    L1SeamChooser? seamChooser,
  }) {
    final t = _tailOf(history, closed, maxContextTokens);
    final frozenCost = closed.fold(0, (m, c) => m + c.tokenCost);

    final closedSegments = <CompactionSegment>[
      for (final c in closed)
        CompactionSegment(
          messages: _spanMessages(history, c.coveredMinSeq, c.coveredMaxSeq),
          summary: true,
          level: c.level, // preserve the closed segment's level (L1 or L2)
          reuse: c,
        ),
    ];
    final tailPlan =
        _foldTail(t.tail, t.budget, _batchThreshold(maxContextTokens), seamChooser);
    return CompactionPlan(
      segments: [
        ...closedSegments,
        ...tailPlan.segments,
      ],
      projectedTokens: frozenCost + tailPlan.projectedTokens,
      shouldCompact: closedSegments.isNotEmpty || tailPlan.shouldCompact,
    );
  }

  /// The (far, k) seam inputs the runtime needs to PREFETCH/MEMOIZE the LLM
  /// level-1 seams (design D5 option A) BEFORE building the final plan.
  ///
  /// Mirrors the pure decision inside [_foldTail] (closed floor → tail → greedy
  /// foldEnd → far → k) so the seam memo key computed here equals the far span +
  /// k that `_batchL1(far, T, seamChooser)` will re-derive internally.
  /// Still a pure function — it only exposes the seam inputs so the LLM seam can
  /// be computed once (memoized), then replayed deterministically. Returns null
  /// when there is nothing to fold (empty tail / under budget).
  static ({List<Message> far, int k})? resolveFoldSeamInputs({
    required List<Message> history,
    required int maxContextTokens,
    List<ClosedSummary> closed = const [],
  }) {
    final t = _tailOf(history, closed, maxContextTokens);
    if (t.tail.isEmpty) return null;
    if (ContextEstimator.estimateConversation(t.tail) <= t.budget) return null;
    final T = _batchThreshold(maxContextTokens);
    final foldEnd = _nominalFoldEnd(t.tail, T);
    if (foldEnd <= 0) return null;
    final far = t.tail.sublist(0, foldEnd);
    if (far.isEmpty) return null;
    final k = _countL1Batches(far, T);
    return (far: far, k: k);
  }

  /// The unclosed tail + its budget, shared by [buildTree] and
  /// [resolveFoldSeamInputs] (single source of truth for progressive closure).
  static ({List<Message> tail, int budget}) _tailOf(
      List<Message> history, List<ClosedSummary> closed, int maxContextTokens) {
    final closedFloor = closed.isEmpty
        ? -1
        : closed.map((c) => c.coveredMaxSeq).reduce((a, b) => a > b ? a : b);
    final frozenCost = closed.fold(0, (m, c) => m + c.tokenCost);
    var tailStart = 0;
    while (tailStart < history.length &&
        (history[tailStart].seq ?? 0) <= closedFloor) {
      tailStart++;
    }
    final tailBudget = (maxContextTokens - frozenCost) < 0
        ? 0
        : maxContextTokens - frozenCost;
    return (tail: history.sublist(tailStart), budget: tailBudget);
  }

  /// Messages of [history] whose seq lies in [minSeq..maxSeq] (oldest → newest).
  static List<Message> _spanMessages(List<Message> history, int minSeq, int maxSeq) {
    return history.where((m) {
      final s = m.seq ?? 0;
      return s >= minSeq && s <= maxSeq;
    }).toList();
  }

  /// Fold plan for the not-yet-closed tail: far span batched into level-1
  /// summary segments, near span kept verbatim (newest).
  ///
  /// Pure/deterministic STRUCTURE only (design D4): it fixes the batch
  /// boundaries (accumulated RAW token > T, oldest-first) and which newest
  /// content stays verbatim. It does NOT estimate any summary's size (no `/4`),
  /// so [projectedTokens] is the RAW trigger size — the real post-compaction
  /// budget fit is measured at runtime by the measure→adjust loop (⑪.3), which
  /// performs the level-2 coarsening and oldest-omit.
  static CompactionPlan _foldTail(
      List<Message> messages, int budget, int T, L1SeamChooser? seamChooser) {
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

    // Nominal far/near split: keep a bounded NEWEST (recent-chunk) span verbatim
    // (raw ≤ T = maxContextTokens~/2 — the spec's "which newest content stays
    // verbatim", a recent-chunk cap, not "all newest up to budget"), fold the older
    // rest. Runtime refines the budget fit via measurement (⑪.3). Safe-aligned
    // inside [_nominalFoldEnd] so the near span begins on a legal cut point (never
    // splits a tool round).
    var foldEnd = _nominalFoldEnd(messages, T);
    // Heavy-closed edge (budget < T, so the whole tail's raw ≤ T but > budget):
    // _nominalFoldEnd returns 0 — every message fits the batch threshold, so all
    // would be verbatim, but raw > budget so we MUST fold to fit. Fold only the
    // OLDER content and KEEP a bounded NEWEST-verbatim tail (D3/D4 "最新始终
    // verbatim" — never fold the newest): grow verbatim from the newest while its
    // raw ≤ budget, then safe-align. A single newest message > budget is folded
    // anyway (D3's documented pathological known-limit), not dropped.
    if (foldEnd <= 0) {
      foldEnd = messages.length;
      var acc = 0;
      for (var i = messages.length - 1; i >= 0; i--) {
        final mCost = ContextEstimator.estimateMessage(messages[i]);
        if (acc + mCost <= budget) {
          acc += mCost;
          foldEnd = i;
        } else {
          break;
        }
      }
      foldEnd = _alignToSafeBoundary(messages, foldEnd);
    }
    // far[0] (the fold's first message) is EXEMPT from "never begin a summary on an
    // assistant carrying tool_calls": it is the fold's FIRST message, so there is no
    // foldable message before it to split a tool round WITH — its synthetic
    // user(tool_result) is emitted from the same assistant Message by
    // _buildApiMessages. (The whole-conversation index 0 is likewise exempt; the
    // exemption carries to a progressive-closure tail that begins on a tool round.)
    // Interior batch boundaries remain safe-snapped in _batchL1.
    final far = messages.sublist(0, foldEnd);
    final near = messages.sublist(foldEnd);

    final segments = <CompactionSegment>[
      ..._batchL1(far, T, seamChooser),
      if (near.isNotEmpty) CompactionSegment(messages: near, summary: false),
    ];
    return CompactionPlan(
      segments: segments,
      // Nominal trigger size (raw) — real post-compaction size is measured at
      // runtime (⑪.3). Kept as the uncompressed projection for observability.
      projectedTokens: totalProxy,
      shouldCompact: segments.any((s) => s.summary),
    );
  }

  /// Nominal verbatim (near) split: keep the newest messages verbatim while the
  /// accumulated RAW token total stays ≤ [T] (= maxContextTokens~/2, a bounded
  /// recent-chunk cap — the spec's "which newest content stays verbatim"); the
  /// remaining older messages are the fold (far) span. Safe-boundary aligned (near
  /// never starts mid-tool). Shared by [_foldTail] and [resolveFoldSeamInputs].
  static int _nominalFoldEnd(List<Message> messages, int T) {
    var foldEnd = messages.length;
    var acc = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final mCost = ContextEstimator.estimateMessage(messages[i]);
      if (acc + mCost <= T) {
        acc += mCost;
        foldEnd = i;
      } else {
        break;
      }
    }
    return _alignToSafeBoundary(messages, foldEnd);
  }

  /// Interior L1 batch boundaries (each = start index of a batch after the first)
  /// computed by RAW-token accumulation: cut a batch when the accumulated proxy
  /// token total strictly exceeds [T] (design D3/D4, oldest-first). Pure +
  /// deterministic. Each boundary is snapped FORWARD to the next SAFE cut point
  /// so a summary batch never begins on an assistant carrying tool_calls (unsafe
  /// messages absorbed into the preceding batch — coarser, never splits a tool
  /// round). [far.length] is the implicit end (no trailing boundary returned).
  static List<int> _rawBatchBoundaries(List<Message> far, int T) {
    final boundaries = <int>[];
    var acc = 0;
    for (var i = 0; i < far.length; i++) {
      acc += ContextEstimator.estimateMessage(far[i]);
      if (acc > T) {
        // Cut the batch ending at [i]; the next batch starts at i+1 (valid only
        // if that is not the empty end).
        if (i + 1 < far.length) boundaries.add(i + 1);
        acc = 0;
      }
    }
    final snapped = <int>[];
    for (var s in boundaries) {
      while (s < far.length && !_isSafeBoundary(far[s])) {
        s++;
      }
      if (s < far.length && (snapped.isEmpty || s > snapped.last)) {
        snapped.add(s);
      }
    }
    return snapped;
  }

  /// Number of L1 batches for [far] under raw-token threshold [T] (the `k` seam
  /// input). Mirrors the arithmetic inside [_batchL1] so [resolveFoldSeamInputs]
  /// exposes the SAME k that buildTree re-derives internally.
  static int _countL1Batches(List<Message> far, int T) {
    if (far.isEmpty) return 0;
    return _rawBatchBoundaries(far, T).length + 1;
  }

  /// Batch [far] into level-1 summary segments by RAW-token threshold [T]
  /// (oldest-first, deterministic).
  ///
  /// WHEN a valid [seamChooser] is provided (design D5 option A: "AI micro-adjusts
  /// the batch boundary to the nearest safe topic seam"), its k-1 seams REPLACE
  /// the raw-token interior boundaries IF they validate (safe, strictly
  /// increasing, exactly k-1, inside the span); otherwise the arithmetic raw-token
  /// skeleton is used. A misbehaving seam can never split a tool round or change
  /// the batch count.
  static List<CompactionSegment> _batchL1(
      List<Message> far, int T, L1SeamChooser? seamChooser) {
    if (far.isEmpty) return [];
    final boundaries = _rawBatchBoundaries(far, T);
    final k = boundaries.length + 1;
    if (seamChooser != null && k > 1) {
      final seams = _normalizeSeams(seamChooser(far, k), far, k);
      if (seams != null) return _segmentsFromSeams(far, seams);
    }
    final segments = <CompactionSegment>[];
    var start = 0;
    for (final boundary in boundaries) {
      if (boundary > start) {
        segments.add(
            CompactionSegment(messages: far.sublist(start, boundary), summary: true));
        start = boundary;
      }
    }
    if (start < far.length) {
      segments.add(CompactionSegment(messages: far.sublist(start), summary: true));
    }
    return segments;
  }

  /// Validate an AI-chosen seam list against [far] and the target count [k]: it
  /// must contain exactly k-1 interior boundaries, each strictly inside the span,
  /// strictly increasing, and each on a SAFE boundary (real user text / terminal
  /// assistant with no tool_calls — never an assistant carrying tool_calls). Any
  /// violation → null (caller falls back to the arithmetic-safe skeleton).
  static List<int>? _normalizeSeams(List<int>? seams, List<Message> far, int k) {
    if (seams == null || far.length < 2) return null;
    if (seams.length != k - 1) return null;
    var prev = 0;
    for (final s in seams) {
      if (s <= prev || s >= far.length) return null;
      if (!_isSafeBoundary(far[s])) return null;
      prev = s;
    }
    return List<int>.of(seams);
  }

  /// Build L1 segments by cutting [far] at the validated [seams] (each the start
  /// index of a segment after the first). Cover is dense + complete: the union of
  /// segment messages equals [far], with no duplicates and no gaps.
  static List<CompactionSegment> _segmentsFromSeams(
      List<Message> far, List<int> seams) {
    final segments = <CompactionSegment>[];
    var start = 0;
    for (final boundary in seams) {
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

  /// Public safety check (spec "Safe segment boundary choice"): lets the runtime
  /// seam selector build the safe-candidate list and lets tests assert the rule.
  /// Mirrors [_isSafeBoundary].
  static bool isSafeBoundary(Message m) => _isSafeBoundary(m);

  /// Raw proxy token total of a verbatim span (deterministic, known pre-send).
  /// The runtime measure→adjust loop uses this as the verbatim cost; summaries'
  /// sizes are only known after the summarization call (⑪.1 real output_tokens).
  static int rawTokens(List<Message> msgs) => ContextEstimator.estimateConversation(msgs);

  /// How many of the OLDEST summary entries roll into ONE level-2 "summary of
  /// summaries" group (design D3/D4): accumulate the oldest entries' MEASURED
  /// [tokens] from the start and cut when the running sum first exceeds the
  /// threshold [T] (0 → empty input). Pure + deterministic given measured sizes;
  /// a single entry already exceeding T yields a group of 1.
  static int l2GroupCount(List<int> tokens, int T) {
    if (tokens.isEmpty) return 0;
    var acc = 0;
    for (var i = 0; i < tokens.length; i++) {
      acc += tokens[i];
      if (acc > T) return i + 1;
    }
    return tokens.length;
  }

  /// [startSeq, endSeq] span of a segment's messages, for recording an L2's
  /// underlying L1 sub-spans (l2SubSpans).
  static List<int> segmentSpan(CompactionSegment s) {
    if (s.messages.isEmpty) return [0, 0];
    return [(s.messages.first.seq ?? 0), (s.messages.last.seq ?? 0)];
  }
}
