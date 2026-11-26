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
