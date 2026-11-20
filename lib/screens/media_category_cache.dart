import '../data/app_settings_store.dart';

/// In-memory copy of the remembered media-tab categories, filled once at boot.
///
/// `MediaTabController` restores its category synchronously from this map, so
/// the first `load()` still starts the provider fetch immediately. Reading the
/// keychain from inside `load()` added an `await` before the fetch, which broke
/// callers that rely on the load starting in the same turn (and the pinned
/// `media_tab_controller_test` gate).
final Map<String, String?> _cache = {};

String _key(String sourceId, String kind) => '$sourceId\u0000$kind';

/// The category the user last browsed for this source/kind, or null for "All".
String? cachedMediaCategory(String sourceId, String kind) =>
    _cache[_key(sourceId, kind)];

/// Keeps the cache in step when the user switches category.
void cacheMediaCategory(String sourceId, String kind, String? categoryId) {
  _cache[_key(sourceId, kind)] = categoryId;
}

/// Test isolation: the cache is process-wide by design, so a suite that
/// constructs several controllers for the same demo source must start each case
/// from "nothing remembered".
void resetMediaCategoryCacheForTest() => _cache.clear();

/// Reads the remembered category for every source, once, at boot.
///
/// Two keychain reads per source and kind. Failures are swallowed: an
/// unreadable preference simply means "All" for that tab.
Future<void> preloadMediaCategoryPrefs(Iterable<String> sourceIds) async {
  const settings = AppSettingsStore();
  for (final sourceId in sourceIds) {
    for (final kind in const ['movie', 'series']) {
      try {
        cacheMediaCategory(
          sourceId,
          kind,
          await settings.mediaCategory(sourceId, kind),
        );
      } catch (_) {
        cacheMediaCategory(sourceId, kind, null);
      }
    }
  }
}
