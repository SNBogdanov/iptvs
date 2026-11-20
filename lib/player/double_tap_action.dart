import 'package:flutter/foundation.dart';

import '../data/app_settings_store.dart';

/// What a double tap on the picture does.
///
/// Two choices, both halves-of-the-screen gestures: the **left half** goes back
/// or to the previous channel, the **right half** forward or next. Which of the
/// two actions that means is the user's call, because the two are wanted by
/// different viewers: a film watcher expects ±N seconds (the YouTube gesture),
/// while someone zapping channels expects the next/previous channel.
enum DoubleTapAction {
  /// Steps to the previous/next channel on live, or the previous/next film or
  /// episode on VOD — only where the session actually has a list to walk.
  previousNext('prev_next', 'Previous / Next'),

  /// Seeks back/forward by the configured seek step. Titles only: live has no
  /// position to seek, so a double tap there does nothing.
  seek('seek', 'Seek');

  const DoubleTapAction(this.storageValue, this.label);

  /// Wire/disk name, shared verbatim with the Android Activity
  /// (`EXTRA_DOUBLE_TAP`), so it must not be renamed casually.
  final String storageValue;
  final String label;

  static DoubleTapAction parse(String? raw) {
    for (final value in DoubleTapAction.values) {
      if (value.storageValue == raw) return value;
    }
    return DoubleTapAction.previousNext;
  }

  DoubleTapAction get other => this == DoubleTapAction.previousNext
      ? DoubleTapAction.seek
      : DoubleTapAction.previousNext;
}

/// Live mirror of the stored choice. Settings is unreachable from a player
/// route, so the overlay reads this synchronously at build time.
///
/// **Previous / Next is the default**, and absence is the default too: it is the
/// only one of the two that has something to do on *every* kind of stream (live
/// channels as well as films), so a setting nobody opened still reacts to a
/// double tap instead of being inert on half the catalogue.
final ValueNotifier<DoubleTapAction> doubleTapAction = ValueNotifier(
  DoubleTapAction.previousNext,
);

/// Reads the stored choice into [doubleTapAction]. Called once at boot.
Future<void> loadDoubleTapAction({AppSettingsStore? store}) async {
  doubleTapAction.value = DoubleTapAction.parse(
    await (store ?? const AppSettingsStore()).rawDoubleTapAction(),
  );
}

/// Sets the choice and persists it. Publishes first, persists second: a failed
/// write must not leave the session behaving like the old choice after the user
/// watched the label change.
Future<void> setDoubleTapAction(
  DoubleTapAction value, {
  AppSettingsStore? store,
}) async {
  doubleTapAction.value = value;
  await (store ?? const AppSettingsStore()).setRawDoubleTapAction(
    // `previousNext` is the default, so writing it back would make the keychain
    // look like a choice the user made.
    value == DoubleTapAction.previousNext ? null : value.storageValue,
  );
}
