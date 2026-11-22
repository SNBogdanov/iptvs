/// The order a **paged** catalogue read is served in.
///
/// The grid's own enum is `MediaSort` in `screens/`, which the data layer must
/// not import (layering: `data/` is below `screens/`). This is the same ladder
/// expressed as a storage concern, and the controller maps one to the other in
/// one place.
///
/// **The order is applied by SQL, not by Dart**, because a VOD catalogue is
/// read in windows now: a comparator over the *loaded* window would order each
/// page separately and put "Newest first" out of order across page boundaries.
/// `sort_date` (`releaseSortKey`, filled at write time and backfilled) is what
/// makes the release-date order expressible in SQL at all — `year` carries the
/// provider's own format (`2026-09-29`, `29.09.2026`, `2026`), which SQL cannot
/// parse.
library;

/// A paged read's ordering.
enum MediaOrder {
  releaseDateDesc,
  releaseDateAsc,
  titleAsc,
  titleDesc,
  providerOrder,
}
