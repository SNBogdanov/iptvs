import 'package:flutter/foundation.dart';

import '../data/app_settings_store.dart';
import 'seek_step.dart';

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

/// Whether the channel/title name is drawn. Default **true** — the name the
/// chrome's top bar already carries.
///
/// The peer of [showPlayerClock] for the picture's other side: the shared
/// overlay keeps the name on screen **top-left** while the chrome is down,
/// mirroring the clock badge it keeps top-right.
final ValueNotifier<bool> showChannelName = ValueNotifier<bool>(true);

/// How far one Left/Right press, or one `-N`/`+N` tap, moves a VOD position,
/// in seconds. Default [kDefaultSeekStepSeconds] (10).
///
/// The peer of the toggles above, and a notifier for the same reason: the
/// Settings tile and the player chrome must agree, and the chrome reads it
/// **synchronously** — the `-N`/`+N` button labels and the arrow-step amount are
/// drawn from it on the frame the chrome appears. Unlike the toggles it is not a
/// bool, so [kSeekStepChoices] is the whole vocabulary and [normalizeSeekStep]
/// guards the read.
final ValueNotifier<int> seekStepSeconds =
    ValueNotifier<int>(kDefaultSeekStepSeconds);

/// Reads the persisted preferences into the notifiers, so the chrome reflects
/// the saved values from the first frame.
///
/// **Awaited** from `main()` before `runApp`, unlike the neighbouring
/// `unawaited` preference loads. Those push a runner window style and cannot be
/// observed in a frame; these gate chrome that is on screen at t=0, so a load
/// that landed after the first paint would briefly draw the clock the user had
/// turned off. All are local keychain reads (the Windows backend is a DPAPI
/// file), so the cost is a file read either way.
Future<void> loadPlayerChromePrefs({AppSettingsStore? store}) async {
  final settings = store ?? const AppSettingsStore();
  showPlayerClock.value = await settings.showPlayerClock();
  showPlaybackTimes.value = await settings.showPlaybackTimes();
  showChannelName.value = await settings.showChannelName();
  seekStepSeconds.value = await settings.seekStepSeconds();
}