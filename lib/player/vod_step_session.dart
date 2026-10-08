// The list a VOD title was launched from, so the transport can step to the
// episode before or after this one.
//
// Its own leaf module, and **pure where it can be**: which neighbour a step
// reaches, and whether there is one at all, are decided by `indexForStep` and
// nothing else. That is the whole of the interesting behaviour — the same kind
// of separation `live_zap_index.dart` makes for a live zap — and keeping it out
// of the route means the ordering and the bounds are pinned by a unit test
// instead of by a media_kit widget test that needs a real player.
//
// Deliberately **not** a playlist abstraction. The list arrives already
// filtered and ordered by whoever launched the title — the season's episode
// list, the visible VOD page, the continue-watching rail, a favourites view —
// because each of those already owns its own ordering rule and has already paid
// to build the list. Re-sorting here would be a second copy of a rule that
// lives elsewhere, and the copy would drift.

import '../sources/source.dart';

/// One step's target, resolved against a launch context.
typedef VodStepResolver = Future<StreamInfo?> Function(MediaItem item);

/// The siblings of the title now playing, and which of them it is.
///
/// Created by the launch site, which is the only place that knows both the
/// ordered list and how to turn one of its rows into a playable stream.
class VodStepSession {
  /// The siblings, in the order the launching surface displayed them. Not
  /// re-ordered, not re-filtered — see the class doc.
  final List<MediaItem> items;

  /// Which of [items] is on screen. Asserted in range: a session whose cursor
  /// does not address its own list cannot answer a step, and a half-valid one
  /// would step to an arbitrary neighbour rather than fail loudly.
  final int index;

  /// Turns a sibling into a playable stream, owned by the launch site.
  ///
  /// A callback rather than a [Source], deliberately. An episode needs the
  /// season's `parent` to resolve (it carries the cached `cmd` — one of the
  /// sealed-locator reveal points), and for a cross-source favourites view each
  /// row has its own owning provider. Only the caller holds both.
  final VodStepResolver resolve;

  const VodStepSession({
    required this.items,
    required this.index,
    required this.resolve,
  }) : assert(index >= 0, 'a session must address its own list');

  bool get isEmpty => items.isEmpty;

  /// The sibling [previous] steps away, or null when the step leaves the list.
  MediaItem? neighbour({required bool previous}) {
    final target = vodStepIndex(
      length: items.length,
      index: index,
      previous: previous,
    );
    return target == null ? null : items[target];
  }
}

/// The index a step reaches, or null when it leaves the list.
///
/// Split out as a free function so the bounds rule is testable without building
/// a [MediaItem] list — and so the contrast with [liveZapIndex], which wraps at
/// both ends because a channel list has no ends, is a one-line comparison
/// rather than a change buried in a method.
///
/// **Never wraps**, unlike a live zap. Wrapping is what makes PgDn usable on a
/// set-top box, where there is no last channel; for a film or a season it would
/// mean episode 1 stepping back into the previous season, and for a VOD page it
/// would teleport across the user's filtered catalogue. The end is a real place
/// to stop, so both ends answer null.
int? vodStepIndex({
  required int length,
  required int index,
  required bool previous,
}) {
  if (length <= 0 || index < 0 || index >= length) return null;
  final target = previous ? index - 1 : index + 1;
  return target < 0 || target >= length ? null : target;
}
