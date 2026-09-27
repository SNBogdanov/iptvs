import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey;

import '../player/zap_command.dart'
    show kDigitEntryCommitDelay, kDigitEntryKeys, kDigitEntryMaxDigits;
import '../sources/source.dart';

/// Every physical key that types a channel number, mapped to the digit it
/// types. Numpad included, because a desktop keyboard reaches the live list
/// with either and a remote's digit row is `digit0`..`digit9`.
///
/// **The map itself lives in [kDigitEntryKeys]**, shared with the in-player zap
/// controller, so a number typed on the live list and one typed in the player
/// read the same keys with the same timing. Two copies of a key map drift the
/// moment a remote or a numpad row is added to one of them.
final Map<LogicalKeyboardKey, int> channelNumberKeys = kDigitEntryKeys;

/// The keys that confirm the typed number. All three, because they are three
/// different buttons: a desktop keyboard's Enter, a keypad's Enter, and a
/// remote/TV's Select (the same physical OK the list plays on).
final Set<LogicalKeyboardKey> channelNumberCommitKeys = {
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.select,
};

/// Which group a number jump has to show for the target channel, or
/// [currentGroupId] to stay where it is.
///
/// The live list is a selection model, so a channel it does not draw cannot be
/// selected at all — the jump has to widen the view before it can take the
/// cursor. The ladder is the order the views are nested in:
///
///   1. **the group the user is already in** — a number that names a channel in
///      the visible group must not move the sidebar;
///   2. **"All channels"** — the one view that contains every category the user
///      has not disabled;
///   3. **Favorites** — a favorite is shown even from a category the user
///      disabled (see `_computeVisible`), so that view is the last one that can
///      still draw such a channel.
///
/// **A null return is a group, not an absence of one**: `null` is the "All
/// channels" id (the ladder's own second rung), so it must not be read as "no
/// jump". When no view can draw the channel at all — an unmatchable one, which
/// the search space is meant to prevent — the ladder ends on [currentGroupId],
/// leaving the view alone rather than inventing one; the caller then selects
/// nothing, because the group it already had cannot draw the row either.
///
/// [drawsTarget] answers "would this group draw the channel, with the name
/// search ignored?" — the search is not a group and is cleared separately, so
/// the caller supplies the predicate against the data it owns and this stays a
/// pure ladder. [favoritesGroupId] is the Favorites view's id, and null when
/// there is no such view to fall back to.
///
/// Pinned by `test/channel_number_entry_test.dart`.
String? planNumberJumpGroup({
  required String? currentGroupId,
  required bool Function(String? groupId) drawsTarget,
  String? favoritesGroupId,
}) {
  if (drawsTarget(currentGroupId)) return currentGroupId;
  if (drawsTarget(null)) return null;
  if (favoritesGroupId != null && drawsTarget(favoritesGroupId)) {
    return favoritesGroupId;
  }
  return currentGroupId;
}

/// A channel number is at most this many digits. Shared with the in-player zap
/// controller, so both ends of the same gesture accept the same length.
const int kMaxChannelNumberDigits = kDigitEntryMaxDigits;

/// How long a partial number waits for one more digit before it is accepted.
/// Shared with the in-player zap controller: typing a channel number is one
/// gesture in both places, and two copies of the timing would be two
/// behaviours to learn.
const Duration kChannelNumberCommitDelay = kDigitEntryCommitDelay;

/// How long a **full-length** number waits before it switches, even though
/// nothing can disambiguate it any further.
///
/// A full-length number used to commit on the keystroke, which is correct as
/// matching and wrong as *interface*: the commit is also what swaps the
/// picture, and the chip that shows what you typed goes with it, so a four-digit
/// number was on screen for a single frame. The digits are the only feedback
/// that the buffer took — while you are still typing, the match is a
/// suggestion, and there is no way to tell a landing channel from a partial
/// prefix until it has already been acted on.
///
/// One second is enough to read four digits and to change your mind (Back /
/// Escape clears), and short enough that a deliberate entry still feels like
/// it responded to the fourth key rather than to a stopwatch. The same pause is
/// what makes a wrong digit recoverable, which the keystroke commit made
/// impossible.
const Duration kChannelNumberFullLengthCommitDelay = Duration(seconds: 1);

/// What the entry chip prints under the digits when nothing matches them. An
/// explicit "nothing here" rather than an empty line, so a mistyped number is
/// visibly a mistyped number and not a chip that stopped updating.
const String kNoChannelNumberMatch = 'No Data Found';

/// The channel [digits] selects out of [channels], or null when nothing does.
///
/// **Exact first, then prefix, and the exact pass never yields to a prefix
/// match that happens to sit earlier in the list.** `2001` listed before `200`
/// would otherwise swallow every `200` typed to reach it, which is precisely
/// the case the two rules exist to serve: typing `200` with no channel `200` is
/// meant to land on `2001`, while typing `200` when a channel `200` *does*
/// exist must reach that one wherever it sits in the catalog.
///
/// The prefix pass is in list order, so "partial match" resolves to the first
/// channel whose number starts with the digits — the catalog's own order, not
/// a sort. A channel with no number never matches.
///
/// Pinned by `test/channel_number_entry_test.dart`.
Channel? matchChannelNumber(List<Channel> channels, String digits) {
  if (digits.isEmpty) return null;
  final exact = int.tryParse(digits);
  for (final channel in channels) {
    if (exact != null && channel.number == exact) return channel;
  }
  for (final channel in channels) {
    final number = channel.number;
    if (number != null && '$number'.startsWith(digits)) return channel;
  }
  return null;
}

/// Typed channel numbers: the buffer, its match, and the commit rules — shared
/// verbatim by both surfaces that accept a number, the live list's chip and the
/// fullscreen player, so the two can never disagree about what a digit does.
///
/// Deliberately knows nothing about groups, focus or playback: it owns the
/// digits and hands the resolved [Channel] to [onCommitted], and each host
/// decides what committing *means* there (select the row, retarget the preview,
/// swap the playing stream). A timer is the only clock it keeps.
class ChannelNumberEntry extends ChangeNotifier {
  ChannelNumberEntry({
    required this.channels,
    required this.onCommitted,
    this.commitDelay = kChannelNumberCommitDelay,
    this.fullLengthCommitDelay = kChannelNumberFullLengthCommitDelay,
    this.maxDigits = kMaxChannelNumberDigits,
  });

  /// The channels a number may resolve against — the host's **whole** catalog,
  /// never the visible page. A number is a jump, not a search: matching it
  /// against the rows the current group happens to draw would make the same
  /// digits resolve to different channels depending on where the user was.
  final List<Channel> Function() channels;

  /// Called with the resolved channel when the buffer is confirmed. May be
  /// async internally (the player resolves a stream before it plays); it is
  /// fired, not awaited, because a key handler cannot suspend.
  final void Function(Channel channel) onCommitted;

  final Duration commitDelay;

  /// The pause before a **full-length** number switches. Shorter than
  /// [commitDelay]: a partial number may still be extended, so it waits out
  /// the possibility of another digit; a full-length one cannot, and the only
  /// thing the shorter pause is buying is the time to read it and change your
  /// mind.
  final Duration fullLengthCommitDelay;

  final int maxDigits;

  String _digits = '';
  Channel? _match;
  Timer? _timer;
  bool _disposed = false;

  /// The digits typed so far, in order.
  String get digits => _digits;

  /// Whether a number is being typed. An arrow press while this is true drops
  /// the buffer: navigating away from a half-typed number is a decision to stop
  /// entering it, and leaving the chip up over a moving cursor reads as a
  /// pending jump that is about to fire.
  bool get isActive => _digits.isNotEmpty;

  /// The channel the current digits resolve to, or null when nothing does. This
  /// is what the chip's second line names — a *live* match, so a partial number
  /// shows the user what they are about to land on before they commit.
  Channel? get match => _match;

  /// The chip's second line: the match's name, or the explicit no-match label.
  String get matchLabel => _match?.name ?? kNoChannelNumberMatch;

  /// Consumes the digit and commit keys, and reports whether the key belonged
  /// to number entry. Repeat and key-up events are swallowed too, so a held
  /// digit cannot re-append and a held OK cannot commit twice.
  bool handleKey(KeyEvent event) {
    final digit = channelNumberKeys[event.logicalKey];
    if (digit != null) {
      if (event is KeyDownEvent) appendDigit(digit);
      return true;
    }
    if (isActive && channelNumberCommitKeys.contains(event.logicalKey)) {
      if (event is KeyDownEvent) commit();
      return true;
    }
    return false;
  }

  void appendDigit(int digit) {
    if (_digits.length >= maxDigits) return;
    _digits += '$digit';
    _match = matchChannelNumber(channels(), _digits);
    _timer?.cancel();
    _timer = null;
    _timer = Timer(
      _digits.length >= maxDigits ? fullLengthCommitDelay : commitDelay,
      commit,
    );
    _notify();
  }

  /// Confirms the buffer: fires [onCommitted] with the match, if there is one,
  /// and always clears it. A commit with no match is a no-op beyond clearing —
  /// the chip has already said `No Data Found`, and there is nothing else to
  /// do about it (never a silent jump to whatever happens to be selected).
  void commit() {
    final typed = _digits;
    final target = matchChannelNumber(channels(), typed);
    _clear();
    if (typed.isEmpty || target == null) return;
    onCommitted(target);
  }

  /// Drops the buffer without committing.
  void clear() => _clear();

  void _clear() {
    _timer?.cancel();
    _timer = null;
    if (_digits.isEmpty && _match == null) return;
    _digits = '';
    _match = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
