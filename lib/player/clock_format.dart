import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';

import '../data/diagnostics_log.dart';

/// The operating system's regional date/time format, resolved once at boot and
/// used by the player's clock badge (docs/player.md "The clock badge's regional
/// format").
///
/// The **long date is the string NLS already formatted for today** — produced by
/// the same `GetDateFormatEx` the Windows GDI badge calls. That is deliberate:
/// NLS inflects a month that sits next to a day number, so the mask `d MMMM yyyy
/// 'г.'` yields the genitive "6 октября 2026 г.", whereas any reconstruction
/// from month-name constants prints the standalone nominative "6 октябрь 2026 г.".
/// Only the **time** is formatted here, because it ticks; [dateFor] records the
/// day the date string describes so a player left running across midnight can
/// re-ask ([refreshClockFormatIfStale]).
class ClockFormat {
  ClockFormat({
    required this.longDate,
    required this.dateFor,
    required this.shortTime,
    required this.am,
    required this.pm,
  });

  /// NLS's long date for [dateFor], e.g. `6 октября 2026 г.`.
  final String longDate;

  /// The local day [longDate] describes (time part zeroed).
  final DateTime dateFor;

  /// The `LOCALE_SSHORTTIME` picture, e.g. `H:mm` (24-hour) or `h:mm tt`
  /// (12-hour). The operating system decides which; this class never
  /// second-guesses it.
  final String shortTime;

  /// The ante-/post-meridiem designators (empty on a 24-hour locale).
  final String am;
  final String pm;

  /// Parses the native map, or null if the patterns are missing or blank. **Fail
  /// closed:** a half-understood format must leave the English fallback in charge
  /// rather than throw while a player is being drawn.
  static ClockFormat? fromMap(Map<Object?, Object?> raw, DateTime now) {
    final longDate = raw['longDate'];
    final shortTime = raw['shortTime'];
    if (longDate is! String || longDate.isEmpty) return null;
    if (shortTime is! String || shortTime.isEmpty) return null;
    return ClockFormat(
      longDate: longDate,
      dateFor: DateTime(now.year, now.month, now.day),
      shortTime: shortTime,
      am: raw['am'] is String ? raw['am']! as String : '',
      pm: raw['pm'] is String ? raw['pm']! as String : '',
    );
  }

  /// Whether [longDate] still describes [now]'s local day.
  bool isForDay(DateTime now) =>
      dateFor.year == now.year &&
      dateFor.month == now.month &&
      dateFor.day == now.day;

  /// The badge text: the long date plus the short time when [dated], else the
  /// short time alone.
  String format(DateTime now, {required bool dated}) {
    final time = _applyTime(shortTime, now);
    if (!dated) return time;
    return '$longDate$kClockDateSeparator$time';
  }

  /// Runs the short-time picture. A time picture only needs clock tokens
  /// (`h`/`hh`/`H`/`HH`, `m`/`mm`, `s`/`ss`, `t`/`tt`), quoted literals like
  /// `'h'` and `\` escapes; anything else is copied verbatim rather than guessed
  /// at, so an unusual locale degrades to a stray token instead of a wrong time.
  String _applyTime(String pattern, DateTime now) {
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
        out.write(_timeToken(ch, j - i, now));
        i = j;
        continue;
      }
      out.write(ch);
      i++;
    }
    return out.toString();
  }

  String _timeToken(String letter, int count, DateTime now) {
    switch (letter) {
      case 'h':
        final hour = now.hour % 12 == 0 ? 12 : now.hour % 12;
        return count == 1 ? '$hour' : _two(hour);
      case 'H':
        return count == 1 ? '${now.hour}' : _two(now.hour);
      case 'm':
        return count == 1 ? '${now.minute}' : _two(now.minute);
      case 's':
        return count == 1 ? '${now.second}' : _two(now.second);
      case 't':
        final marker = now.hour < 12 ? am : pm;
        if (count == 1) return marker.isEmpty ? '' : marker[0];
        return marker;
      default:
        return letter * count;
    }
  }

  static bool _isAsciiLetter(String ch) {
    final code = ch.codeUnitAt(0);
    return (code >= 0x41 && code <= 0x5A) || (code >= 0x61 && code <= 0x7A);
  }
}

/// What joins the date and the time halves of the dated clock badge. A middle
/// dot, matching the separator the badge has always used on every surface, so
/// localizing the halves does not also change the punctuation between them.
const String kClockDateSeparator = ' · ';

/// The resolved format, or null while it has not answered. Read synchronously by
/// the player overlay, so it is process-global like `isTelevision` rather than a
/// widget-owned value.
ClockFormat? clockFormat;

/// Overrides the resolved format for tests. Restore it in a `tearDown` — this is
/// process-global, and a leaked fake would silently change every later player
/// test's clock.
@visibleForTesting
set debugClockFormat(ClockFormat? value) => clockFormat = value;

/// Resolves [clockFormat] from the platform, once. Safe to call again.
///
/// Only Windows implements the channel: the Windows native surface is the one
/// that must agree with this function, and the other platforms draw their own
/// clock in their own overlay. Everywhere else this is a no-op and the caller
/// keeps the English fallback, which is the behaviour that shipped.
///
/// Fired **unawaited** from `main`: nothing reads the clock until a player route
/// is opened, which is at least a profile pick and a catalogue load away, so it
/// has always landed before any chrome exists. Awaiting it would put a platform
/// round trip on the path to the first frame for a value nothing can consume yet.
Future<void> detectClockFormat() async {
  if (!Platform.isWindows) return;
  try {
    final raw = await const MethodChannel('iptvs/clock')
        .invokeMethod<Map<Object?, Object?>>('locale')
        .timeout(const Duration(seconds: 2));
    final parsed = raw == null ? null : ClockFormat.fromMap(raw, DateTime.now());
    if (parsed == null) {
      DiagnosticsLog.instance.addAndPrint(
        'player',
        'clock format unavailable: empty or malformed',
      );
      return;
    }
    clockFormat = parsed;
  } catch (error) {
    DiagnosticsLog.instance.addAndPrint(
      'player',
      'clock format unavailable: ${error.runtimeType}',
    );
  }
}

/// Re-asks for the format once the day [clockFormat] describes has passed, so a
/// player left running across midnight does not keep printing yesterday's date.
/// Cheap and idempotent — the overlay calls it on its clock tick; it returns
/// immediately on any day but the rollover.
Future<void> refreshClockFormatIfStale() async {
  final current = clockFormat;
  if (current == null || !Platform.isWindows) return;
  if (current.isForDay(DateTime.now())) return;
  await detectClockFormat();
}

String _two(int value) => value.toString().padLeft(2, '0');
