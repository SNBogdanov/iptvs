import 'dart:async';

import 'package:clock/clock.dart';

import 'diagnostics_log.dart';
import 'net.dart';

/// Keeps the paired profile's favorites in step with the cloud without the user
/// having to press Push.
///
/// **Pull is safe, push is a delta.** A pull only ever mirrors the profile, so
/// it runs on app start and on profile switch. A push carries only what changed
/// locally (`push_favorites_delta`), which is what makes running it
/// automatically safe at all: the whole-set `push_favorites` would let two
/// devices on their own schedules erase each other's additions, because a
/// missing element and a deletion look identical in a full set.
///
/// **No revision guard, deliberately.** An earlier design pushed the whole set
/// and compared `profiles.updated_at` to detect an intervening change. The
/// delta merge makes that unnecessary rather than merely cheaper: the server
/// applies each row under the profile's row lock, so concurrent pushes
/// serialise and two devices can only conflict on the *same* favorite — where
/// "whichever arrived last" is the answer a revision check would have given
/// anyway.
///
/// Pushes are debounced: favoriting five channels in a row is one round trip,
/// not five. The debounce also keeps this well inside the server's 30-per-minute
/// push budget, which auto-pushing shares with manual pushes rather than
/// getting a budget of its own.
///
/// The same class drives the watch-state sync with [ticketExtend] set (a ticket
/// that keeps sliding while playback keeps writing) and a [flushRequests]
/// stream (the player saying it stopped).
class CloudAutoSync {
  /// Mirrors the profile into the local cache. Must not throw for the caller —
  /// failures are logged and retried on the next trigger.
  final Future<void> Function() pull;

  /// Sends pending local changes (favorite toggles, or watch-state entries).
  /// Returns true when it sent anything.
  final Future<bool> Function() push;

  /// Fires whenever a local change relevant to this sync happens
  /// (`AppDatabase.favoritesChanged`, `AppDatabase.watchChanged`).
  final Stream<void> changes;

  /// Optional "send now" requests — e.g. the player reporting that it stopped
  /// watching a title. Listening here keeps call sites from having to know the
  /// sync object exists.
  final Stream<void>? flushRequests;

  final Duration debounce;

  /// When set, this is a **ticket** rather than a plain debounce: the first
  /// change schedules a push [debounce] away, and each further change moves
  /// that same ticket [ticketExtend] later instead of restarting the full
  /// window.
  ///
  /// That is the difference between "coalesce a burst" and "save the position
  /// of something being watched": a player writes a position every 30 s of
  /// continuous playback, so a plain debounce would either never fire (each
  /// write restarts the window) or fire instantly. Extending by a second keeps
  /// the push roughly [debounce] after the *first* unsent change, and a
  /// genuinely continuous stream of writes slides it only slightly.
  final Duration? ticketExtend;

  /// Backoff after a failed push. A failure is usually the network or a rate
  /// limit, and the change is still in the outbox, so retrying soon is both
  /// safe and pointless to hurry.
  final Duration retryDelay;

  CloudAutoSync({
    required this.pull,
    required this.push,
    required this.changes,
    this.flushRequests,
    this.debounce = const Duration(seconds: 5),
    this.ticketExtend,
    this.retryDelay = const Duration(seconds: 30),
  });

  StreamSubscription<void>? _sub;
  StreamSubscription<void>? _flushSub;
  Timer? _timer;
  DateTime? _deadline;
  bool _pushing = false;
  bool _pendingWhilePushing = false;
  bool _disposed = false;

  /// True while a debounced push is scheduled or running — for tests and for a
  /// "syncing…" affordance.
  bool get busy => _timer != null || _pushing;

  /// Begins listening for local changes. [pullFirst] mirrors the profile once
  /// before doing so, which is what makes a fresh install or a device that has
  /// been away pick up the other devices' favorites.
  Future<void> start({bool pullFirst = true}) async {
    if (_disposed) return;
    _sub ??= changes.listen((_) => _schedule());
    _flushSub ??= flushRequests?.listen((_) {
      unawaited(flush());
    });
    if (pullFirst) await pullNow();
    // A device that was offline when the user last toggled something still has
    // it queued; send it once the pull has established a baseline.
    _schedule();
  }

  Future<void> pullNow() async {
    if (_disposed) return;
    try {
      await pull();
    } catch (error) {
      // Never rethrow into whatever triggered the sync (app start, a profile
      // switch): the app works offline, and a failed mirror is not a failed
      // launch.
      DiagnosticsLog.instance.add(
        'cloud',
        'auto-sync pull failed: ${redactText('$error')}',
      );
    }
  }

  void _schedule() {
    if (_disposed) return;
    if (_pushing) {
      // Coalesce into one follow-up rather than stacking timers behind the
      // in-flight push.
      _pendingWhilePushing = true;
      return;
    }
    final now = clock.now();
    final extension = ticketExtend;
    final deadline = _deadline;
    _deadline = deadline == null || extension == null
        ? now.add(debounce)
        : deadline.add(extension);
    final wait = _deadline!.difference(now);
    _timer?.cancel();
    _timer = Timer(wait.isNegative ? Duration.zero : wait, _flush);
  }

  Future<void> _flush() async {
    _timer = null;
    _deadline = null;
    if (_disposed) return;
    if (_pushing) {
      // A flush requested mid-push must not be swallowed: the in-flight push
      // may predate the change that asked for it.
      _pendingWhilePushing = true;
      return;
    }
    _pushing = true;
    try {
      await push();
    } catch (error) {
      DiagnosticsLog.instance.add(
        'cloud',
        'auto-sync push failed, will retry: ${redactText('$error')}',
      );
      // The change is still in the outbox; a later trigger or this retry sends
      // it. Nothing is lost by failing here.
      if (!_disposed) {
        _timer?.cancel();
        _timer = Timer(retryDelay, _flush);
      }
    } finally {
      _pushing = false;
    }
    if (_pendingWhilePushing && !_disposed) {
      _pendingWhilePushing = false;
      _schedule();
    }
  }

  /// Sends anything pending right now, bypassing the debounce — for app
  /// backgrounding or a profile switch, where waiting out the timer would mean
  /// the change is still sitting in the outbox when the profile changes under
  /// it.
  Future<void> flush() async {
    _timer?.cancel();
    _timer = null;
    await _flush();
  }

  Future<void> dispose() async {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    await _sub?.cancel();
    _sub = null;
    await _flushSub?.cancel();
    _flushSub = null;
  }
}
