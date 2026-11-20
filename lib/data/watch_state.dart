import '../sources/source.dart';

/// The display snapshot the cloud keeps next to a title's state: what the panel
/// can render without a catalogue.
///
/// Deliberately **not** part of [WatchState.sameState] — changing a poster does
/// not change what the user watched, and a pull must not rewrite local progress
/// just because a title was renamed upstream. The cloud merge treats an empty
/// value as "this device does not know" and keeps what it has, so a device that
/// no longer has the item in its catalogue cannot blank the snapshot another
/// device stored.
class WatchMeta {
  final String title;
  final String year;
  final String poster;

  /// The wide artwork. The panel draws history thumbnails in landscape (16:9),
  /// and a 2:3 poster cropped to that ratio loses most of the picture, so the
  /// row stores both and the panel prefers this one.
  final String backdrop;

  const WatchMeta({
    this.title = '',
    this.year = '',
    this.poster = '',
    this.backdrop = '',
  });

  static const empty = WatchMeta();

  bool get isEmpty =>
      title.isEmpty && year.isEmpty && poster.isEmpty && backdrop.isEmpty;

  /// The server bounds (see `watch_state_meta_check`). Clipped here rather than
  /// rejected: one 600-character provider title must not fail an entire push
  /// batch, and the value is display text, not an identity.
  WatchMeta clipped() => WatchMeta(
    title: _clip(title, 512),
    year: _clip(year, 32),
    poster: isValidPoster(poster) ? _clip(poster, 2048) : '',
    backdrop: isValidPoster(backdrop) ? _clip(backdrop, 2048) : '',
  );

  static String _clip(String value, int max) =>
      value.length <= max ? value : value.substring(0, max);

  /// Only http(s) reaches the panel's `<img src>`; anything else is dropped
  /// instead of being refused (the rest of the entry is still valid state).
  static bool isValidPoster(String value) =>
      value.isEmpty ||
      value.startsWith('http://') ||
      value.startsWith('https://');
}

/// One title's cloud-synced watch state: either a resume point (with a
/// position inside a known duration) or the terminal "watched" mark.
///
/// Mirrors the two local tables it is built from — `playback_positions`
/// ([AppDatabase] keeps them mutually exclusive, exactly as this class does) —
/// and is what a delta push carries and a pull applies.
///
/// **A cleared state is a real value, not an absence.** `watched: false` with
/// `positionMs: 0` means "this title has no state any more" (the user removed
/// it from Continue watching, or un-watched it). A delta has to say that
/// outright: the server has no tombstones and cannot infer a deletion from a
/// missing element, the same reason favorites carry `add`/`remove` rather than
/// a set.
class WatchState {
  final String sourceId;
  final ContentKind kind;
  final String itemId;
  final int positionMs;
  final int durationMs;
  final bool watched;

  /// Display snapshot, filled at push time from the device's catalogue
  /// ([WatchMeta]). Local state never needs it — the app resolves ids itself.
  final WatchMeta meta;

  /// When this local row was last written, for the outbox only — the cloud
  /// carries no client clock (the server stamps its own arrival time). Null for
  /// a state that did not come out of the local outbox.
  final int? updatedAtMs;

  const WatchState({
    required this.sourceId,
    required this.kind,
    required this.itemId,
    this.positionMs = 0,
    this.durationMs = 0,
    this.watched = false,
    this.meta = WatchMeta.empty,
    this.updatedAtMs,
  });

  /// The kinds that carry watch state. Seasons are containers and live has no
  /// timeline, so neither is ever queued or pushed.
  static const kinds = [
    ContentKind.movie,
    ContentKind.series,
    ContentKind.episode,
  ];

  static bool accepts(ContentKind kind) => kinds.contains(kind);

  /// Identity: the same triple the local tables and the server row use.
  String get key => '$sourceId\u0000${kind.name}\u0000$itemId';

  /// Nothing left to remember about this title.
  bool get cleared => !watched && positionMs <= 0;

  WatchState asCleared() => WatchState(
    sourceId: sourceId,
    kind: kind,
    itemId: itemId,
    updatedAtMs: updatedAtMs,
  );

  /// A copy carrying the display snapshot, as sent to the cloud.
  WatchState withMeta(WatchMeta value) => WatchState(
    sourceId: sourceId,
    kind: kind,
    itemId: itemId,
    positionMs: positionMs,
    durationMs: durationMs,
    watched: watched,
    meta: value,
    updatedAtMs: updatedAtMs,
  );

  /// True when both describe the same stored state. Timestamps are deliberately
  /// ignored: a re-derived row with a fresher stamp is not a change. So is the
  /// display snapshot — a renamed title is not a new position.
  bool sameState(WatchState other) =>
      watched == other.watched &&
      positionMs == other.positionMs &&
      durationMs == other.durationMs;

  /// The element a delta push carries. Metadata is omitted when unknown, so the
  /// server keeps whatever another device stored (its merge treats an absent or
  /// empty value as "not known here", never as a clear).
  Map<String, dynamic> toCloudJson() {
    final display = meta.clipped();
    return {
      'source_id': sourceId,
      'kind': kind.name,
      'item_id': itemId,
      'position_ms': positionMs,
      'duration_ms': durationMs,
      'watched': watched,
      if (display.title.isNotEmpty) 'title': display.title,
      if (display.year.isNotEmpty) 'year': display.year,
      if (display.poster.isNotEmpty) 'poster': display.poster,
      if (display.backdrop.isNotEmpty) 'backdrop': display.backdrop,
    };
  }

  /// Parse a `watch_state` row, or null when it is not a shape this client can
  /// apply. Defensive like [cloudRowToConfig]: cloud rows are untrusted input,
  /// and one malformed element must not abort a whole pull.
  static WatchState? fromCloudRow(Map<String, dynamic> row) {
    final sourceId = row['source_id']?.toString();
    final itemId = row['item_id']?.toString();
    final kind = ContentKind.values.asNameMap()[row['kind']?.toString() ?? ''];
    if (sourceId == null ||
        sourceId.isEmpty ||
        itemId == null ||
        itemId.isEmpty ||
        kind == null ||
        !accepts(kind)) {
      return null;
    }
    return WatchState(
      sourceId: sourceId,
      kind: kind,
      itemId: itemId,
      positionMs: _nonNegativeInt(row['position_ms']),
      durationMs: _nonNegativeInt(row['duration_ms']),
      watched: row['watched'] == true,
      meta: WatchMeta(
        title: row['title']?.toString() ?? '',
        year: row['year']?.toString() ?? '',
        poster: row['poster']?.toString() ?? '',
        backdrop: row['backdrop']?.toString() ?? '',
      ).clipped(),
    );
  }

  static int _nonNegativeInt(Object? value) {
    final parsed = value is int
        ? value
        : value is num
        ? value.toInt()
        : int.tryParse(value?.toString() ?? '');
    if (parsed == null || parsed < 0) return 0;
    return parsed;
  }

  @override
  String toString() =>
      'WatchState($sourceId/${kind.name}/$itemId '
      'pos=$positionMs dur=$durationMs watched=$watched)';
}

/// What a pull has to write and what it has to clear.
class WatchPullPlan {
  /// Rows to apply, as the cloud has them.
  final List<WatchState> writes;

  /// Local rows the cloud no longer has, as cleared states.
  final List<WatchState> clears;

  const WatchPullPlan(this.writes, this.clears);

  static const empty = WatchPullPlan([], []);

  bool get isEmpty => writes.isEmpty && clears.isEmpty;
}

/// Decide a pull's effect without touching the database — pure, so the rule can
/// be tested on its own.
///
/// **The cloud wins, except where this device has an unsent change.** [local]
/// is the merged local view (positions + watched marks) for the cloud-managed
/// sources; [pending] is the outbox. A title with a queued change is skipped in
/// both directions: the device is about to tell the cloud what it thinks, and
/// overwriting it here would visibly undo the user's action only to re-send it a
/// moment later (the same rebase `pullFavorites` does). A local row the cloud
/// has never heard of, with nothing queued, is a deletion the other device
/// made — mirror it, or it would be pushed straight back up.
WatchPullPlan planWatchPull({
  required Iterable<WatchState> remote,
  required Iterable<WatchState> local,
  required Iterable<WatchState> pending,
}) {
  final pendingKeys = {for (final p in pending) p.key};
  final remoteByKey = <String, WatchState>{};
  for (final row in remote) {
    if (!WatchState.accepts(row.kind) || row.cleared) continue;
    remoteByKey[row.key] = row;
  }
  final localByKey = <String, WatchState>{};
  for (final row in local) {
    if (!WatchState.accepts(row.kind) || row.cleared) continue;
    localByKey[row.key] = row;
  }

  final writes = <WatchState>[];
  for (final entry in remoteByKey.entries) {
    if (pendingKeys.contains(entry.key)) continue;
    if (localByKey[entry.key]?.sameState(entry.value) ?? false) continue;
    writes.add(entry.value);
  }

  final clears = <WatchState>[];
  for (final entry in localByKey.entries) {
    if (remoteByKey.containsKey(entry.key)) continue;
    if (pendingKeys.contains(entry.key)) continue;
    clears.add(entry.value.asCleared());
  }

  if (writes.isEmpty && clears.isEmpty) return WatchPullPlan.empty;
  return WatchPullPlan(writes, clears);
}
