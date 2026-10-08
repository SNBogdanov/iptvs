// A provider's runtime, printed for a catalogue card.
//
// Its own leaf module for the same reason `sources/release_date.dart` is: the
// string is shown in more than one card layout (the VOD grid tile and the
// narrow list row) and a second copy of a zero-pad would be free to drift from
// the first. The continue-watching rail deliberately does **not** print it —
// that thumbnail is a video frame of the title itself, so a runtime there reads
// as metadata about a still image.

/// Formats [seconds] as `MM:SS` under an hour, `H:MM:SS` at an hour or above.
///
/// A sub-hour clip gets the compact form because the leading field is dropped
/// entirely: `00:47` is a runtime, while `0:00:47` — a full three-field shape
/// padded to a clock — reads as time spent rather than time long. Above an hour
/// the `H` is *not* padded, which is the other half of the same distinction
/// (`0:47:30` / `1:05:07` are runtimes, `00:47:30` is a time of day). The two
/// remaining fields are always two digits, so `1:05:07` and `12:05:07` line up
/// in the same card column and `01:05` lines up under them.
///
/// Returns null for a non-positive or absent value: a portal that reports `0`
/// or a missing field means "unknown runtime", and printing `00:00` would state
/// a runtime nobody gave.
String? formatMediaDuration(int? seconds) {
  if (seconds == null || seconds <= 0) return null;
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  String two(int v) => v.toString().padLeft(2, '0');
  if (hours == 0) return '${two(minutes)}:${two(secs)}';
  return '$hours:${two(minutes)}:${two(secs)}';
}
