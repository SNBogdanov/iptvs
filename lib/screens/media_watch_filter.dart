import '../sources/source.dart';

bool isMediaWatched(Map<String, double> progress, String id) {
  final value = progress[id];
  return value != null && value >= 1.0;
}

List<MediaItem> mediaWithoutWatched(
  List<MediaItem> items,
  Map<String, double> progress,
) {
  if (progress.isEmpty) return items;
  final filtered = items.where((item) => !isMediaWatched(progress, item.id));
  return filtered.length == items.length ? items : filtered.toList();
}

MediaItem? firstUnwatchedMedia(
  List<MediaItem> items,
  Map<String, double> progress,
) {
  for (final item in items) {
    if (!isMediaWatched(progress, item.id)) return item;
  }
  return null;
}
