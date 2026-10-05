/// How often a source's catalogue (live channels + VOD) is refreshed
/// automatically, and the pure decision of whether it is due.
///
/// **Device-side only.** The choice is a per-source preference stored in
/// `SourceConfig.settings['refreshInterval']`, but *when the last refresh ran* is
/// deliberately kept out of that blob — it rides the source row into the cloud,
/// so a last-run timestamp there would push a rewrite on every refresh and hand a
/// paired device a clock reading that means nothing on it. The timestamp lives in
/// the keychain (`data/source_refresh_store.dart`), the same argument the expiry
/// cache and the last-watched channel make.
///
/// This is the *catalogue* schedule only: **channels and VOD, never the EPG.**
/// The guide has its own freshness window (`LibraryRepository._epgMaxAge`) and
/// its own ingest coordinator, and a large XMLTV download forced on every
/// catalogue refresh is exactly what that separation exists to avoid.
enum SourceRefreshInterval {
  /// Refresh on every app start, regardless of how recently one ran.
  atStartup('startup', null, 'At startup'),
  every6h('6', 6, 'Every 6 hours'),
  every12h('12', 12, 'Every 12 hours'),
  every24h('24', 24, 'Every 24 hours'),
  every48h('48', 48, 'Every 48 hours');

  const SourceRefreshInterval(this.storageValue, this.hours, this.label);

  /// What `SourceConfig.settings['refreshInterval']` holds.
  final String storageValue;

  /// The period, or null for [atStartup] (which ignores elapsed time).
  final int? hours;

  /// The row label in the source-settings screen.
  final String label;

  /// 24 hours. A daily refresh keeps a provider's new titles reachable without
  /// re-ingesting a large catalogue on every launch; only an absent or
  /// unrecognised value reads as this, so an explicit choice is always honoured.
  static const SourceRefreshInterval defaultInterval = every24h;

  /// Parses a stored value. Anything unknown — absent, a value a newer build
  /// wrote, a corrupted string — falls back to [defaultInterval] rather than
  /// being read as "never" or "every launch".
  static SourceRefreshInterval parse(Object? raw) {
    final value = raw?.toString();
    for (final interval in values) {
      if (interval.storageValue == value) return interval;
    }
    return defaultInterval;
  }
}

/// Whether [interval] says a refresh is due, given the last refresh time.
///
/// Pure, so the schedule is pinned without a keychain, a clock or a source.
/// A null [last] means "never refreshed" and is always due — an untouched
/// source has nothing cached, and refusing to refresh it would be the one
/// wrong answer.
bool planSourceRefresh(
  SourceRefreshInterval interval,
  DateTime? last,
  DateTime now,
) {
  final hours = interval.hours;
  if (hours == null) return true;
  if (last == null) return true;
  return now.difference(last) >= Duration(hours: hours);
}
