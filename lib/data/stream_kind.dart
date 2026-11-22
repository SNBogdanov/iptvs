import '../sources/source.dart' show ContentKind;

/// The content kind a **playback stream** belongs to.
///
/// Three, not four: Settings offers "Live / Movies / Series", and an episode is
/// a series — a viewer does not think of a season as a separate route. Seasons
/// and episodes therefore map to series.
///
/// Lives in its own file because both sides of the proxy setting need it
/// (`AppSettingsStore` keys the switch by it, the player chooses an endpoint by
/// it) and neither should depend on the other's module.
enum StreamKind {
  live('live'),
  movie('movie'),
  series('series');

  const StreamKind(this.storageName);

  /// The key fragment in `AppSettingsStore` (`app_stream_proxy_<name>`).
  final String storageName;

  String get label => switch (this) {
    StreamKind.live => 'Live',
    StreamKind.movie => 'Movies',
    StreamKind.series => 'Series',
  };
}

StreamKind streamKindOf(ContentKind kind) => switch (kind) {
  ContentKind.live => StreamKind.live,
  ContentKind.movie => StreamKind.movie,
  ContentKind.series ||
  ContentKind.season ||
  ContentKind.episode => StreamKind.series,
};
