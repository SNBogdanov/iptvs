import 'dart:typed_data';

/// Per-row geometry of the live channel list.
///
/// The live list used to be a **uniform** row height: one channel with a guide
/// entry made *every* row tall (112 px), so a catalog whose guide covers a
/// handful of channels spent the whole list's second, third and fourth lines on
/// nothing. Rows are now sized individually — a channel with no programme is
/// drawn at the plain height — and this object is the exact, cheap answer to
/// "where does row N start and how tall is it".
///
/// It stays exact rather than approximate on purpose. The keyboard selection
/// model reveals rows by arithmetic (`index * extent` in the uniform version),
/// and an approximate answer is the known "cursor is on the right channel but
/// the list looks somewhere else" bug. `ListView.builder`'s `itemExtentBuilder`
/// takes the same [extentAt], and [offsetAt]/[total] give the reveal its exact
/// numbers without the framework's estimate of unbuilt children.
///
/// Only two heights exist (plain and with-EPG), so the prefix sums are built
/// lazily — up to the index actually asked for — and the whole structure is
/// immutable per catalog/epg state. Nothing here reads Flutter or the models:
/// [tallAt] is the caller's predicate.
class LiveRowLayout {
  LiveRowLayout({
    required this.count,
    required this.plain,
    required this.withEpg,
    required this.tallAt,
  });

  /// Number of rows.
  final int count;

  /// Height of a row that draws no programme (channel name only).
  final double plain;

  /// Height of a row that draws now/next/progress.
  final double withEpg;

  /// Whether row [index] draws a programme, and therefore takes [withEpg].
  final bool Function(int index) tallAt;

  /// Offset of row [index] **plus one**: `_prefix[i]` is the top of row `i`.
  /// Grown on demand, so a reveal of row 5 costs five entries even in a
  /// 250k-row catalog.
  Float64List? _prefix;

  /// `_prefix[filled]` == top of row `filled`; rows `[0, filled)` are summed.
  int _filled = 0;

  bool get isUniform => plain == withEpg;

  double extentAt(int index) {
    // Defensive: the list and this object are built from the same catalog, but
    // an off-by-one during a rebuild must not throw from inside a sliver
    // layout pass.
    if (count == 0) return plain;
    return tallAt(index.clamp(0, count - 1)) ? withEpg : plain;
  }

  /// Total height of every row. Built in full the first time it is asked for —
  /// only a reveal needs it (to clamp against the real end of the list instead
  /// of the framework's estimate).
  double get total {
    if (count == 0) return 0;
    _fill(count);
    return _prefix![count];
  }

  /// Top of row [index].
  double offsetAt(int index) {
    if (index <= 0) return 0;
    _fill(index);
    return _prefix![index];
  }

  void _fill(int upTo) {
    if (upTo <= _filled) return;
    // Grow geometrically so a scan to the end is one allocation, and a reveal a
    // few rows down is still cheap.
    var capacity = _prefix?.length ?? 64;
    while (capacity <= upTo) {
      capacity *= 2;
    }
    if (_prefix == null || _prefix!.length < capacity) {
      final next = Float64List(capacity);
      if (_prefix != null) next.setRange(0, _filled + 1, _prefix!);
      _prefix = next;
    }
    final prefix = _prefix!;
    var top = prefix[_filled];
    for (var i = _filled; i < upTo; i++) {
      top += extentAt(i);
      prefix[i + 1] = top;
    }
    _filled = upTo;
  }
}
