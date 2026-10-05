import 'package:flutter/foundation.dart';

import 'app_settings_store.dart';

/// The shape of a VOD/series poster card in the media grid.
///
/// A device preference, not a per-profile one, and not per-source: it is how
/// *this* screen draws artwork, so it belongs with the other global toggles.
enum VodCardOrientation {
  /// 2:3 — the shape TMDB and every provider panel ships, so a card at this
  /// ratio crops nothing.
  portrait,

  /// 16:9 — a cropped horizontal band of the poster. Roughly three times as many
  /// cards fit on screen, at the cost of cutting most artwork top and bottom.
  landscape;

  /// Width over height, the same convention as the grid's `childAspectRatio`.
  double get aspectRatio => switch (this) {
        VodCardOrientation.portrait => 2 / 3,
        VodCardOrientation.landscape => 16 / 9,
      };

  /// What the Settings tile prints, so the two names a user has to recognise
  /// (this, and the shape they are looking at) are the same pair.
  String get label => switch (this) {
        VodCardOrientation.portrait => 'Portrait',
        VodCardOrientation.landscape => 'Landscape',
      };

  /// What gets persisted, or null for the default.
  ///
  /// Only a non-default value is written, matching every other key in
  /// [AppSettingsStore]: an absent key reads as portrait, so nothing has to be
  /// written for the overwhelmingly common case and nothing has to be migrated.
  String? get storageValue =>
      this == VodCardOrientation.portrait ? null : name;

  /// Unrecognised input reads as the default rather than throwing. A keychain
  /// value this build doesn't know is a *forward* value — an older build meeting
  /// a newer one must not fail the grid it was supposed to draw.
  static VodCardOrientation parse(String? raw) {
    for (final value in VodCardOrientation.values) {
      if (value.storageValue == raw) return value;
    }
    return VodCardOrientation.portrait;
  }
}

/// Live mirror of the stored [VodCardOrientation].
///
/// The grid is behind the Settings route rather than rebuilt by it, so a toggle
/// that only wrote the keychain would leave the cards in the old shape until
/// something else happened to reload them. The Settings tile publishes here
/// immediately; `loadVodCardOrientation` fills it once at boot.
///
/// Deliberately a plain `ValueNotifier`, like `alwaysOnTopEnabled` — the only
/// thing a consumer needs is "rebuild when this changes".
final ValueNotifier<VodCardOrientation> vodCardOrientation =
    ValueNotifier<VodCardOrientation>(VodCardOrientation.portrait);

/// Reads the stored preference into [vodCardOrientation]. Called once at boot;
/// until it answers, the notifier holds the default, which is the same value
/// every untouched install has anyway.
Future<void> loadVodCardOrientation({AppSettingsStore? store}) async {
  final settings = store ?? const AppSettingsStore();
  vodCardOrientation.value = VodCardOrientation.parse(
    await settings.rawVodCardOrientation(),
  );
}

/// Sets the orientation and persists it.
///
/// Publishes before awaiting the keychain write, because the write can be slow
/// (a Windows keychain hit) and the point of the toggle is the visible change.
Future<void> setVodCardOrientation(
  VodCardOrientation value, {
  AppSettingsStore? store,
}) async {
  vodCardOrientation.value = value;
  await (store ?? const AppSettingsStore()).setRawVodCardOrientation(
    value.storageValue,
  );
}

/// The other choice from [value]. Two modes only, so the Settings tile cycles
/// rather than opening a picker — one less stop for a remote to reach, and the
/// tile's trailing label already prints which mode is current.
VodCardOrientation otherVodCardOrientation(VodCardOrientation value) =>
    switch (value) {
      VodCardOrientation.portrait => VodCardOrientation.landscape,
      VodCardOrientation.landscape => VodCardOrientation.portrait,
    };