import 'dart:collection';

/// A non-compressible anchor: a user goal, acceptance criterion, or explicit
/// "don't touch X" invariant that must NEVER be folded into a summary, no
/// matter how old. Anchors are bounded, deduplicated, and revocable, and are
/// re-injected on every turn (design D-guard / spec "Non-compressible anchor").
///
/// Source is an explicit standing-requirements mechanism (a caller-provided
/// list), NOT LLM-extraction from prose — extraction is nondeterministic and
/// would undermine the invariant.
class Anchor {
  final String id;
  final String text;
  final DateTime addedAt;
  bool revoked;

  Anchor({required this.id, required this.text, required this.addedAt, this.revoked = false});
}

/// A bounded, deduplicated set of anchors, re-injected each turn as a system
/// prefix (guard). Compaction must treat every anchor as non-compressible and
/// never collapse it; re-injection happens regardless of message age.
class GuardAnchors {
  /// Hard bound so the anchor set can never grow unbounded.
  static const int maxAnchors = 64;

  final List<Anchor> _anchors = [];
  int _nextId = 0;
  bool _enabled = true;

  /// Whether the guard is active. When disabled (e.g. no standing requirements),
  /// [inject] returns empty and compaction is unconstrained by anchors.
  bool get enabled => _enabled;
  void setEnabled(bool v) => _enabled = v;

  /// Register a standing requirement. Deduplicated by normalized text; bounded
  /// by [maxAnchors] (oldest evicted). Idempotent for the same text.
  Anchor add(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw ArgumentError('anchor text must be non-empty');
    final normalized = trimmed.toLowerCase();
    for (final a in _anchors) {
      if (!a.revoked && a.text.toLowerCase() == normalized) return a;
    }
    if (_anchors.length >= maxAnchors) _anchors.removeAt(0);
    final anchor = Anchor(id: 'a${_nextId++}', text: trimmed, addedAt: DateTime.now());
    _anchors.add(anchor);
    return anchor;
  }

  /// Revoke an anchor (e.g. a requirement the user later withdrew). Revoked
  /// anchors are not injected and are eligible for compaction again.
  void revoke(String id) {
    for (final a in _anchors) {
      if (a.id == id) a.revoked = true;
    }
  }

  bool isRevoked(String id) => _anchors.any((a) => a.id == id && a.revoked);

  /// Active (non-revoked) anchors, in insertion order.
  UnmodifiableListView<Anchor> get active =>
      UnmodifiableListView(_anchors.where((a) => !a.revoked).toList());

  /// Seed from an explicit standing-requirements list (replaces current set).
  void setStandingRequirements(List<String> requirements) {
    _anchors.clear();
    _nextId = 0;
    for (final r in requirements) {
      if (r.trim().isNotEmpty) add(r);
    }
    _enabled = requirements.isNotEmpty;
  }

  /// The guard text re-injected each turn. Empty when disabled or no active
  /// anchors. Placed in the system prompt (system stays for real instructions;
  /// this is a fixed, non-folded prefix).
  String inject() {
    if (!_enabled) return '';
    final active = this.active;
    if (active.isEmpty) return '';
    final buf = StringBuffer();
    buf.write('## 不可压缩约束（以下目标/验收标准/不变量绝不折叠，无论多旧）\n');
    for (final a in active) {
      buf.write('- ${a.text}\n');
    }
    return buf.toString().trimRight();
  }
}
