/// Ordering for the movies/series grids.
///
/// Pure, like `favorites_order.dart`: no database, no widget tree, no provider.
/// The provider hands back its own catalogue order, which is fine for a channel
/// list and arbitrary for VOD — a panel that orders by stream id, or by when it
/// last touched a row, is not an order anyone browses by. So the grid sorts, and
/// this file is that rule.
///
/// The release date is a *string* in the model (`MediaItem.year`), because that
/// is all a panel gives: `2026-09-29` on Stalker (the exact key preferred over
/// the year-only one — see `test/stalker_release_date_test.dart`), the same or a
/// bare `2026` on Xtream, `12.05.2023` on European panels. Everything a sort can
/// be sure of is therefore extracted in `releaseSortKey` rather than assumed, and
/// what *isn't* a date is not guessed at — it sorts last.
library;

import '../sources/release_date.dart';
import '../sources/source.dart';

/// How one media tab's grid is ordered.
///
/// [releaseDateDesc] is the default because a VOD catalogue is browsed for
/// what's new, and the provider order is the one order here that isn't about the
/// content at all — so a grid that only ever showed it was never sorted at all.
///
/// [providerOrder] is the escape hatch, and the reason the default costs
/// nothing: a panel that already lists VOD the way its owner wants keeps that
/// listing one keystroke away.
enum MediaSort {
  releaseDateDesc('Newest first'),
  releaseDateAsc('Oldest first'),
  titleAsc('Name A-Z'),
  titleDesc('Name Z-A'),
  providerOrder('As provided');

  /// Short enough for the toolbar dropdown beside the category picker.
  final String label;

  const MediaSort(this.label);

  /// Whether this mode reorders at all — [providerOrder] hands the list back
  /// untouched, so the caller can skip the sort rather than run a comparator
  /// that always returns 0.
  bool get sorts => this != MediaSort.providerOrder;
}

/// Newest first. Pinned as the default by `test/media_sort_test.dart`: changing
/// it is a change of behaviour for every install, not a refactor.
const MediaSort kDefaultMediaSort = MediaSort.releaseDateDesc;

/// Reorders [items] for [sort].
///
/// Returns a **new** list, or [items] itself for fewer than two entries and for
/// [MediaSort.providerOrder] — the caller's list is already freshly built by the
/// filter, and copying a single row to protect it from nothing would be noise.
///
/// The incoming order is the caller's already-correct one — provider order for a
/// catalogue, catalog reading order for Favorites (`orderedByCatalog` runs
/// before this) — and it survives as the tie-break. That is what keeps two
/// undated rows, or two rows with the same title, in the order the grid was
/// already showing instead of reshuffling on every rebuild.
///
/// The tie-break is explicit because **`List.sort` is not stable in Dart**:
/// without it, equal-key rows would shuffle between rebuilds on exactly the list
/// sizes where an unstable introsort starts partitioning.
List<MediaItem> sortedMedia(List<MediaItem> items, MediaSort sort) {
  if (items.length < 2 || !sort.sorts) return items;
  switch (sort) {
    case MediaSort.providerOrder:
      return items;
    case MediaSort.titleAsc:
      return _byTitle(items, descending: false);
    case MediaSort.titleDesc:
      return _byTitle(items, descending: true);
    case MediaSort.releaseDateAsc:
      return _byRelease(items, descending: false);
    case MediaSort.releaseDateDesc:
      return _byRelease(items, descending: true);
  }
}

/// Name order, case-insensitive — a portal that ships `THE MATRIX` and `Alien`
/// in one list must not put every capitalised title ahead of every lowercase one.
List<MediaItem> _byTitle(List<MediaItem> items, {required bool descending}) {
  final rows = [
    for (var i = 0; i < items.length; i++)
      (name: items[i].title.toLowerCase(), given: i, value: items[i]),
  ];
  rows.sort((a, b) {
    final byName = a.name.compareTo(b.name);
    if (byName != 0) return descending ? -byName : byName;
    return a.given.compareTo(b.given);
  });
  return [for (final row in rows) row.value];
}

/// Release-date order.
///
/// **An undated item sorts last in both directions**, and that is the one place
/// the direction is deliberately *not* applied to a comparison. A row with no
/// date is not the oldest film and not the newest, so flipping the control
/// would otherwise move the same undated rows from one end of the grid to the
/// other — a portal that supplies no release dates at all would visibly
/// reshuffle on every flip while showing nothing new. Mirrors
/// `kUnrankedCatalogPosition`'s reasoning for an unranked favorite.
List<MediaItem> _byRelease(List<MediaItem> items, {required bool descending}) {
  final rows = [
    for (var i = 0; i < items.length; i++)
      (date: releaseSortKey(items[i].year), given: i, value: items[i]),
  ];
  rows.sort((a, b) {
    final (aDate, bDate) = (a.date, b.date);
    if (aDate == null || bDate == null) {
      if (aDate == null && bDate == null) return a.given.compareTo(b.given);
      return aDate == null ? 1 : -1;
    }
    if (aDate != bDate) {
      final byDate = aDate.compareTo(bDate);
      return descending ? -byDate : byDate;
    }
    return a.given.compareTo(b.given);
  });
  return [for (final row in rows) row.value];
}
