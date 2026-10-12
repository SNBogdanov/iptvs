// Reading a provider's release-date string: parsing it into a comparable key,
// and printing it back in the OS's own short-date format.
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

/// A release date at the precision the provider gave it: [year] is always
/// present; [month]/[day] are null when the string did not carry them (a bare
/// `2026`, or a `2026-09` whose day the panel truncated).
class ReleaseDateParts {
  const ReleaseDateParts(this.year, [this.month, this.day]);

  final int year;
  final int? month;
  final int? day;

  /// Whether the value names a specific day - i.e. whether a short-date picture
  /// can be applied to it at all. A year-only row has nothing for the day and
  /// month fields to print.
  bool get hasDay => month != null && day != null;
}

/// Reads [raw] (`MediaItem.year`, which deliberately holds whatever precision
/// the provider gave) into its [ReleaseDateParts], or null when it carries no
/// usable date.
///
/// Recognised, in order:
///
/// * `2026-09-29`, `2026/09/29`, optionally with a `T...`/space time tail - the
///   ISO form both Stalker and Xtream emit.
/// * `29.09.2026`, `29-09-2026` - day first, as a European panel writes it. A
///   `05/06/2026` whose day and month could be swapped is read the same way as
///   every other row, so a set of rows keeps its relative order; the ambiguity
///   only matters for a single date printed back to the user, which
///   [formatReleaseDate] then prints the same (day-first) way.
/// * `2026` - a bare year (month and day null).
/// * Any other string carrying a plausible year (`"May 12, 2026"`) - that year,
///   month and day null. This fallback is what keeps a panel with an unexpected
///   date format sortable instead of dumping every one of its rows to the
///   bottom.
ReleaseDateParts? releaseDateParts(String? raw) {
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
    if (_isPlausibleYear(a)) return ReleaseDateParts(a, b, c);
    // Day first: [ReleaseDateParts] wants (year, month, day), and the input is
    // (day, month, year).
    if (_isPlausibleYear(c)) return ReleaseDateParts(c, b, a);
  }
  if (numbers.length == 2 && _isPlausibleYear(numbers[0])) {
    // `YYYY-MM` - a portal that truncates the day. The year is the whole story.
    return ReleaseDateParts(numbers[0], numbers[1]);
  }
  for (final number in numbers) {
    if (_isPlausibleYear(number)) return ReleaseDateParts(number);
  }
  return null;
}

/// A monotonic release key for [raw], or null when it carries no usable date.
///
/// Returns `yyyyMMdd`, so plain integer comparison *is* chronological order.
/// That is what lets both sort directions share one parsed key instead of
/// negating a date into something an undated row can't be compared against, and
/// what lets two dates be ranked against each other without re-parsing either.
/// A bare year is read as Jan 1 of it, so it orders *before* that year's dated
/// rows ascending instead of tying with them.
int? releaseSortKey(String? raw) {
  final parts = releaseDateParts(raw);
  if (parts == null) return null;
  return _key(parts.year, parts.month ?? 0, parts.day ?? 0);
}

/// The short-date picture the OS resolved for the current locale (Windows
/// `LOCALE_SSHORTDATE`: `dd.MM.yyyy`, `M/d/yyyy`, ...), or null until a platform
/// answers. Set once at boot by `player/clock_format.dart`, and read here so the
/// VOD card can print a provider's date the way the machine writes one. Null on
/// every platform whose clock channel does not carry it, which leaves [raw]
/// untouched.
String? systemShortDatePattern;

/// [raw] (`MediaItem.year`) printed the way the machine writes a date.
///
/// The provider reports the shape it likes (`2026-09-29`, `29.09.2026`); the
/// card prints it back in the OS's own short-date format (`29.09.2026` on a
/// Russian Windows, `9/29/2026` on an American one). [pattern] defaults to
/// [systemShortDatePattern].
///
/// Falls back to [raw] verbatim - never a blank - when there is no picture to
/// apply, when the value carries only a year (a bare `2026` needs no
/// reformatting), or when its month/day are out of range. An unparseable string
/// is left exactly as the panel sent it rather than hidden.
String formatReleaseDate(String? raw, {String? pattern}) {
  final text = raw ?? '';
  final parts = releaseDateParts(raw);
  final picture = pattern ?? systemShortDatePattern;
  if (parts == null || !parts.hasDay) return text;
  if (picture == null || picture.isEmpty) return text;
  final month = parts.month!;
  final day = parts.day!;
  if (month < 1 || month > 12 || day < 1 || day > 31) return text;
  return _applyDatePattern(picture, parts.year, month, day);
}

/// Runs a Windows short-date picture (`dd.MM.yyyy`) over one date. Handles the
/// numeric tokens (`d`/`M`/`y`, doubled for zero-padding), quoted literals like
/// `yyyy'年'M'月'd'日'` and `\` escapes; any other letter is copied verbatim
/// rather than guessed at, so an unusual locale degrades to a stray token
/// instead of a wrong date. A short-date picture never contains month or weekday
/// names, so those token runs (`MMM`, `dddd`) are deliberately printed verbatim.
String _applyDatePattern(String pattern, int year, int month, int day) {
  final out = StringBuffer();
  var i = 0;
  while (i < pattern.length) {
    final ch = pattern[i];
    if (ch == "'") {
      i++;
      // A doubled quote inside a quoted run is a literal apostrophe; `''` on
      // its own is one too.
      if (i < pattern.length && pattern[i] == "'") {
        out.write("'");
        i++;
        continue;
      }
      while (i < pattern.length && pattern[i] != "'") {
        out.write(pattern[i]);
        i++;
      }
      if (i < pattern.length) i++;
      continue;
    }
    if (ch == r'\' && i + 1 < pattern.length) {
      out.write(pattern[i + 1]);
      i += 2;
      continue;
    }
    if (_isAsciiLetter(ch)) {
      var j = i;
      while (j < pattern.length && pattern[j] == ch) {
        j++;
      }
      out.write(_dateToken(ch, j - i, year, month, day));
      i = j;
      continue;
    }
    out.write(ch);
    i++;
  }
  return out.toString();
}

String _dateToken(String letter, int count, int year, int month, int day) {
  switch (letter) {
    case 'd':
      if (count >= 3) return letter * count; // weekday name: not modelled
      return count == 1 ? '$day' : _two(day);
    case 'M':
      if (count >= 3) return letter * count; // month name: not modelled
      return count == 1 ? '$month' : _two(month);
    case 'y':
      return count == 2 ? _two(year % 100) : '$year';
    default:
      // Not a date token: print it as the literal it looks like, so an unknown
      // token is visible in the printed date rather than silently dropped.
      return letter * count;
  }
}

bool _isAsciiLetter(String ch) {
  final code = ch.codeUnitAt(0);
  return (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
}

bool _isPlausibleYear(int value) =>
    value >= _kMinPlausibleYear && value <= _kMaxPlausibleYear;

/// `yyyyMMdd`, month and day clamped into range so a padded-but-nonsense date
/// (`2026-13-40`) sorts at the end of its year instead of spilling into 2027.
int _key(int year, int month, int day) =>
    year * 10000 + month.clamp(0, 12) * 100 + day.clamp(0, 31);

String _two(int value) => value.toString().padLeft(2, '0');
