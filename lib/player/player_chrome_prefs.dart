import 'package:flutter/foundation.dart';

import '../data/app_settings_store.dart';

/// Whether the player's wall-clock badge is drawn. Default **true** — the
/// clock every surface draws today.
///
/// Mirrored as a notifier for the same reason [alwaysOnTopEnabled] is: the
/// settings screen and the player chrome have to agree, and the chrome is built
/// from a value that has to be readable **synchronously** on the first frame,
/// because the badge is one `Text`/`Badge`/`BadgeLabel` inside a layout that a
/// late arrival would visibly repaint.
///
/// Deliberately *not* a clock drawn over hidden video. This hides the existing
/// badge; it never adds a persistent one, on any surface.
final ValueNotifier<bool> showPlayerClock = ValueNotifier<bool>(true);

/// Whether the VOD position/duration readout is drawn beside the scrubber.
/// Default true; hides the labels and keeps the bar draggable.
final ValueNotifier<bool> showPlaybackTimes = ValueNotifier<bool>(true);

/// Reads both persisted preferences into the notifiers, so the chrome reflects
/// the saved values from the first frame.
///
/// **Awaited** from `main()` before `runApp`, unlike the neighbouring
/// `unawaited` preference loads. Those push a runner window style and cannot be
/// observed in a frame; these gate chrome that is on screen at t=0, so a load
/// that landed after the first paint would briefly draw the clock the user had
/// turned off. Both are local keychain reads (the Windows backend is a DPAPI
/// file), so the cost is a file read either way.
Future<void> loadPlayerChromePrefs({AppSettingsStore? store}) async {
  final settings = store ?? const AppSettingsStore();
  showPlayerClock.value = await settings.showPlayerClock();
  showPlaybackTimes.value = await settings.showPlaybackTimes();
}