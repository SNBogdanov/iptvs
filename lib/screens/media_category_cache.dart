import '../data/app_settings_store.dart';

/// In-memory copy of the remembered tab categories, filled once at boot.
///
/// Two consumers, one reason: a tab restores its category **synchronously** on
/// its first build, because an `await` on the keychain there would either delay
/// the first provider fetch (`MediaTabController.load()`) or flash "All" for a
/// frame before the stored group arrives (the live sidebar and its phone
/// dropdown). Both read the map, not the keychain.
final Map<String, String?> _mediaCache = {};
final Map<String, String?> _liveCache = {};

String _key(String sourceId, String kind) => '$sourceId\u0000$kind';

/// The category the user last browsed for this source/kind, or null for "All".
String? cachedMediaCategory(String sourceId, String kind) =>
    _mediaCache[_key(sourceId, kind)];

/// Keeps the cache in step when the user switches category.
void cacheMediaCategory(String sourceId, String kind, String? categoryId) {
  _mediaCache[_key(sourceId, kind)] = categoryId;
}

/// The live category the user last browsed for this source, or null for "All".
String? cachedLiveCategory(String sourceId) => _liveCache[sourceId];

/// Keeps the live half in step when the user switches category.
void cacheLiveCategory(String sourceId, String? categoryId) {
  _liveCache[sourceId] = categoryId;
}

/// Test isolation: the caches are process-wide by design, so a suite that
/// constructs several screens for the same demo source must start each case
/// from "nothing remembered".
void resetMediaCategoryCacheForTest() {
  _mediaCache.clear();
  _liveCache.clear();
}

/// Reads the remembered categories for every source, once, at boot.
///
/// Two keychain reads per source for the media tabs plus one for live. Failures
/// are swallowed: an unreadable preference simply means "All" for that tab.
Future<void> preloadTabCategoryPrefs(Iterable<String> sourceIds) async {
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
    try {
      cacheLiveCategory(sourceId, await settings.liveCategory(sourceId));
    } catch (_) {
      cacheLiveCategory(sourceId, null);
    }
  }
}
