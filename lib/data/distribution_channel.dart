/// Who packaged the running build and therefore owns its update lifecycle.
///
/// Only the channels this fork actually ships are listed: GitHub releases
/// ([githubDirect]), side-loaded iOS builds ([altStore]), and local/CI builds
/// ([development]). The former `googlePlay` and `microsoftStore` values went
/// away together with the store publishing path; a stale build reporting one of
/// them parses as [development], which means exactly what it meant for those
/// builds — no self-update.
enum DistributionChannel {
  development,
  githubDirect,
  altStore,
}

DistributionChannel parseDistributionChannel(String value) {
  return switch (value.trim()) {
    'githubDirect' => DistributionChannel.githubDirect,
    'altStore' => DistributionChannel.altStore,
    _ => DistributionChannel.development,
  };
}

extension DistributionChannelPolicy on DistributionChannel {
  bool get ownsDirectUpdates => this == DistributionChannel.githubDirect;

  /// Whether the app may offer the **published release** as an explicit
  /// install. Only development builds do: a GitHub-direct build has the normal
  /// updater (which only ever offers newer versions), and an AltStore build
  /// owns its lifecycle through the store. A side-loaded development build has
  /// no way back on its own, so this is the escape hatch — see
  /// `runReleaseInstall`.
  bool get offersReleaseInstall => this == DistributionChannel.development;

  String get displayName => switch (this) {
    DistributionChannel.development => 'Development',
    DistributionChannel.githubDirect => 'GitHub direct',
    DistributionChannel.altStore => 'AltStore',
  };
}

class DistributionConfig {
  const DistributionConfig._();

  static const rawChannel = String.fromEnvironment(
    'DISTRIBUTION_CHANNEL',
    defaultValue: 'development',
  );

  static final channel = parseDistributionChannel(rawChannel);

  static bool get directUpdaterEnabled => channel.ownsDirectUpdates;

  /// Whether this binary is a **developer build**: an iteration build made to
  /// test a change, not the published release.
  ///
  /// Compile-time, because a release-mode iteration APK is otherwise
  /// indistinguishable from a published one — same package id, same release
  /// signing key, and the same version name while a release is being prepared.
  /// Iteration builds pass `--dart-define=IPTVS_DEV_BUILD=true`; the release
  /// pipeline never does.
  ///
  /// It changes the About page, not the update plumbing: a developer build shows
  /// **"Return to release"** instead of "Check for updates", so the tester can
  /// install the release cut from the very build they just debugged — including
  /// when it carries the same version number.
  static const bool devBuild = bool.fromEnvironment('IPTVS_DEV_BUILD');
}

/// GitHub-direct users may opt into signed prereleases.
///
/// This fork publishes a single channel, so both values read the same
/// `update.json` (see `docs/updates.md`).
enum UpdateTrack { stable, beta }

UpdateTrack parseUpdateTrack(String? value) =>
    value == 'beta' ? UpdateTrack.beta : UpdateTrack.stable;

extension UpdateTrackLabel on UpdateTrack {
  String get storageValue => name;
  String get displayName => this == UpdateTrack.beta ? 'Beta' : 'Stable';
}
