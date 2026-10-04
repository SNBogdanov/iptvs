// Reading a provider's release-date string as a comparable number.
//
// Lives in its own leaf module rather than in `screens/media_sort.dart`
// because two very different layers need the same answer: the VOD grid orders
// rows by it, and `LibraryRepository` uses it to decide whether a metadata
// provider's date is *more* precise than the one the portal already gave. A
// `data/` -> `screens/` import to share one function would invert the layering,
// and a second copy of the parser would be free to drift from the first.

/// Earliest plausible year - anything older is a parser artefact, and letting
/// one through would read as the year 1234 and outrank every real film.
const int _kMinPlausibleYear = 1870;

/// Latest plausible year - a portal's "coming soon" rows sit past today.
const int _kMaxPlausibleYear = 2100;

/// A monotonic release key for [raw], or null when it carries no usable date.
///
/// [raw] is `MediaItem.year`, which deliberately holds whatever precision the
/// provider gave: the exact date when the portal or the metadata API reported
/// one (`2026-09-29`), a bare `2026` when it did not. That variable precision is
/// the contract, not an accident - a bare year is still sortable, just
/// year-granular.
///
/// Returns `yyyyMMdd`, so plain integer comparison *is* chronological order.
/// That is what lets both sort directions share one parsed key instead of
/// negating a date into something an undated row can't be compared against, and
/// what lets two dates be ranked against each other without re-parsing either.
///
/// Recognised, in order:
///
/// * `2026-09-29`, `2026/09/29`, optionally with a `T...`/space time tail - the
///   ISO form both Stalker and Xtream emit.
/// * `29.09.2026`, `29-09-2026` - day first, as a European panel writes it. A
///   `05/06/2026` whose day and month could be swapped is read the same way as
///   every other row, so a set of rows keeps its relative order; the ambiguity
///   would only matter for a single date printed back to the user, which
///   nothing here does.
/// * `2026` - a bare year, read as Jan 1 of it, so it orders *before* that
///   year's dated rows ascending instead of tying with them.
/// * Any other string carrying a plausible year (`"May 12, 2026"`) - that year,
///   as above. This fallback is what keeps a panel with an unexpected date
///   format sortable instead of dumping every one of its rows to the bottom.
int? releaseSortKey(String? raw) {
  if (raw == null) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;

  final numbers = <int>[];
  for (final part in text.split(RegExp(r'[^\d]+'))) {
    if (part.isEmpty) continue;
    final value = int.tryParse(part);
    if (value == null) return null;
    numbers.add(value);
  }
  if (numbers.isEmpty) return null;

  if (numbers.length >= 3) {
    final (a, b, c) = (numbers[0], numbers[1], numbers[2]);
    if (_isPlausibleYear(a)) return _key(a, b, c);
    // Day first: `_key` wants (year, month, day), and the input is
    // (day, month, year).
    if (_isPlausibleYear(c)) return _key(c, b, a);
  }
  if (numbers.length == 2 && _isPlausibleYear(numbers[0])) {
    // `YYYY-MM` - a portal that truncates the day. The year is the whole story.
    return _key(numbers[0], numbers[1], 0);
  }
  for (final number in numbers) {
    if (_isPlausibleYear(number)) return _key(number, 0, 0);
  }
  return null;
}

bool _isPlausibleYear(int value) =>
    value >= _kMinPlausibleYear && value <= _kMaxPlausibleYear;

/// `yyyyMMdd`, month and day clamped into range so a padded-but-nonsense date
/// (`2026-13-40`) sorts at the end of its year instead of spilling into 2027.
int _key(int year, int month, int day) =>
    year * 10000 + month.clamp(0, 12) * 100 + day.clamp(0, 31);
