import 'dart:async';

import 'package:flutter/foundation.dart';

import 'channel_dwell.dart';

/// How often the countdown repaints while the mode is on.
///
/// One second is the whole resolution the chip has any use for — the shortest
/// rung on the ladder is 5 s — and it is a repaint, not a resolve, so a long
/// period costs nothing. Injectable only so tests need not wait it out.
const Duration kAutoSwitchTick = Duration(seconds: 1);

/// Why the countdown is not currently running.
///
/// The mode is a *mode*, not a transport: it stays on across everything, but it
/// must not move the channel while something else legitimately owns it. Each
/// of these is a case where switching would be wrong rather than merely early.
enum AutoSwitchHold {
  /// Running: counting down to the next switch.
  none,

  /// The mode is off. Not a hold — the reason there is no countdown at all.
  off,

  /// A one-entry range has nothing to switch to. Holding rather than
  /// switching to itself every period: a spinner that re-plays the same channel
  /// looks alive and is not.
  nothingToSwitch,

  /// A resolve is in flight. This is the load-bearing one: a zap is
  /// stop → resolve → play, and a provider account is single-connection, so a
  /// switch issued during one asks the portal for a second link before the
  /// first has been handed back.
  settling,

  /// The quick list is open. It owns navigation outright — channels must not
  /// change behind a list the user is reading.
  quickList,

  /// The window is hidden to the tray (boss key / close-to-tray). Playback is
  /// paused on it and no input can reach the player, so switching channels is a
  /// reconnect only a hidden user would pay for — the countdown freezes rather
  /// than reselecting into the dark.
  silenced,
}

extension AutoSwitchHoldX on AutoSwitchHold {
  /// Whether the clock is running, as opposed to merely enabled.
  bool get counting => this == AutoSwitchHold.none;

  /// Whether the mode is on at all, held or not. What an indicator tests to
  /// decide whether to draw **anything** — a chip that disappears while the
  /// mode is on is how a user ends up unable to turn it off.
  bool get active => this != AutoSwitchHold.off;
}

/// The auto-switch session state: the on/off mode, the countdown, and the tick
/// that advances the cursor.
///
/// **Its own [ChangeNotifier], deliberately not the zap controller's.** The zap
/// banner restarts its own hide timer on every `bannerRevision` bump, so a
/// one-second tick routed through the zap notify path would hold that banner up
/// for as long as the mode is on — the banner would never go away. Separating
/// the notifier is what lets the countdown repaint every second while the
/// banner still behaves like a banner.
///
/// The countdown is driven from a **deadline**, not by decrementing, so a tick
/// that arrives late (a busy isolate, a hidden window throttling timers) makes
/// up the difference rather than drifting the period out by that much.
class AutoSwitch extends ChangeNotifier {
  AutoSwitch({
    required this.dwell,
    required this.onAdvance,
    this.tickInterval = kAutoSwitchTick,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// How long each channel rests, from the **playing entry's owning source** —
  /// the same per-entry rule the buffering preset and the aspect mode follow, so
  /// a zap that crosses sources brings that source's pace with it. `null`
  /// before a source has been resolved.
  ChannelDwell? dwell;

  /// What a completed countdown does. Wired to the controller's ordinary
  /// `channelUp`, so an automatic switch is the **same** stop → resolve → play
  /// a keypress produces: there is no second path into playback, and therefore
  /// no way for one of them to learn single-connection behaviour the other
  /// doesn't have.
  final VoidCallback onAdvance;

  final Duration tickInterval;

  /// The clock the deadline is measured against.
  ///
  /// Injectable, and not as a convenience. The countdown is driven from an
  /// absolute deadline rather than by decrementing — that is what makes a late
  /// tick self-correcting instead of stretching the period — and
  /// `fakeAsync` mocks `Timer` but **not** `DateTime.now`, so a wall-clock
  /// deadline is untestable: the fake ticker would fire four "seconds" in
  /// microseconds and every reading would still say five. Weakening the design
  /// to suit the harness would give up the correction; passing the clock in
  /// keeps both.
  final DateTime Function() _now;

  Timer? _ticker;
  DateTime? _deadline;
  bool _enabled = false;
  AutoSwitchHold _hold = AutoSwitchHold.off;
  Duration _remaining = Duration.zero;

  /// Whether the mode is on. Off on open, always — an unattended channel
  /// walker that turned itself on would be playing sound into a room nobody
  /// asked to be filled.
  bool get enabled => _enabled;

  /// Why the clock is paused, or [AutoSwitchHold.none] while it runs. `off`
  /// whenever [enabled] is false.
  AutoSwitchHold get hold => _enabled ? _hold : AutoSwitchHold.off;

  /// Time left before the next switch, frozen while [hold] is not
  /// [AutoSwitchHold.none].
  Duration get remaining => _remaining;

  /// The period actually in force, for a label that wants the total and not
  /// only the remainder. Falls back to the default so a chip is never blank.
  ChannelDwell get period => dwell ?? kDefaultChannelDwell;

  /// Turns the mode on, restarting the countdown from a full period.
  void enable() {
    if (_disposed) return;
    if (!_enabled) {
      _enabled = true;
      _hold = AutoSwitchHold.none;
    }
    _restart();
    notifyListeners();
  }

  /// Turns the mode off and drops the countdown. Idempotent.
  void disable() {
    if (!_enabled && !_tickerRunning) return;
    _enabled = false;
    _hold = AutoSwitchHold.off;
    _stopTicker();
    _deadline = null;
    _remaining = Duration.zero;
    if (!_disposed) notifyListeners();
  }

  /// Flips the mode, and reports which way it went so the caller can say so.
  bool toggle() {
    if (_enabled) {
      disable();
      return false;
    }
    enable();
    return true;
  }

  /// Re-reads the world and starts, stops or freezes the clock to match.
  ///
  /// Called by the controller on every state change it already reacts to,
  /// rather than the mode watching the world itself: the conditions are the
  /// controller's own (`settling`, `quickListOpen`, range size, the window
  /// being hidden to the tray) and there is one of each.
  void sync({
    required bool settling,
    required bool quickListOpen,
    required int entryCount,
    bool silenced = false,
  }) {
    if (_disposed) return;
    if (!_enabled) return;
    final next = silenced
        ? AutoSwitchHold.silenced
        : entryCount < 2
        ? AutoSwitchHold.nothingToSwitch
        : settling
        ? AutoSwitchHold.settling
        : quickListOpen
        ? AutoSwitchHold.quickList
        : AutoSwitchHold.none;
    if (next != _hold) {
      _hold = next;
      notifyListeners();
    }
    if (next == AutoSwitchHold.none) {
      _ensureTicker();
    } else {
      // Freeze rather than cancel: a list the user closes should not restart
      // the count from the top, which would read as the mode having stopped
      // and restarted on its own.
      _stopTicker();
      _remaining = _left() ?? _remaining;
    }
  }

  /// Restarts the countdown from a full period.
  ///
  /// Called for **every** channel change, manual or automatic, so a user who
  /// zaps by hand gets a full period to look at what they chose rather than
  /// being yanked off it a moment later. That is the whole difference between
  /// auto-switch being a background feature and it being a fight.
  void restart() {
    if (_disposed || !_enabled) return;
    _restart();
    notifyListeners();
  }

  /// The owning source's pace changed mid-session (a cross-source zap). Adopt
  /// it without losing the current countdown's remaining time — a period that
  /// silently restarted on every source change would make a cross-source
  /// session feel like it was stalling.
  void adoptDwell(ChannelDwell? value) {
    if (_disposed || value == null || value == dwell) return;
    dwell = value;
    if (_enabled) {
      _restart();
      notifyListeners();
    }
  }

  void _restart() {
    _deadline = _now().add(period.duration);
    _remaining = period.duration;
    _ensureTicker();
  }

  Duration? _left() {
    final deadline = _deadline;
    if (deadline == null) return null;
    final left = deadline.difference(_now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get _tickerRunning => _ticker?.isActive ?? false;

  void _ensureTicker() {
    if (_tickerRunning || !_enabled || _hold != AutoSwitchHold.none) return;
    _ticker = Timer.periodic(tickInterval, (_) => _onTick());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  void _onTick() {
    if (_disposed) return;
    final left = _left();
    if (left == null) return;
    if (left > Duration.zero) {
      // Second-resolution display: rounding *up* means the chip shows "1s" for
      // the last full second rather than flashing "0s" before the switch.
      final shown = Duration(
        seconds: (left.inMilliseconds / 1000).ceil(),
      );
      if (shown != _remaining) {
        _remaining = shown;
        notifyListeners();
      }
      return;
    }
    // Due. Restart first, so a switch that throws or finds nothing still
    // leaves a running countdown rather than a stopped mode that looks on.
    _restart();
    onAdvance();
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _stopTicker();
    super.dispose();
  }
}

/// The chip's text, printed verbatim by every surface that draws it — natives
/// render this string and derive nothing, so the countdown reads the same on
/// the Flutter overlay, the Windows GDI overlay and the Lua OSD.
///
/// Empty when there is nothing to draw: an off mode draws **nothing** rather
/// than an "off" chip, because a permanent control that is only ever reporting
/// absence is clutter. What it must never do is go blank while the mode is on.
String autoSwitchChipLabel(AutoSwitch auto) {
  if (!auto.enabled) return '';
  final period = auto.period.seconds;
  return switch (auto.hold) {
    AutoSwitchHold.none => '${auto.remaining.inSeconds.clamp(1, period)}s',
    // Held: show the full period it will wait once released, and say why, so a
    // frozen countdown is distinguishable from a hung one.
    AutoSwitchHold.settling => '$period s · switching',
    AutoSwitchHold.quickList => '$period s · list open',
    AutoSwitchHold.nothingToSwitch => '$period s · one channel',
    AutoSwitchHold.silenced => '$period s · hidden',
    AutoSwitchHold.off => '',
  };
}
