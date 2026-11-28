import 'package:flutter/foundation.dart' show ValueNotifier;

import '../sources/source.dart';
import 'app_settings_store.dart';

/// The channel list's sections — **Live**, **Movies**, **Series** — as the
/// viewer chose to see them.
///
/// Device-wide, and an `app_*` key, so it rides the per-device settings backup
/// like every other preference. **Never empty**: at least one section has to
/// stay, or the list would have nothing to draw; the settings screen refuses to
/// turn the last one off and [saveVisibleContentTabs] refuses an empty set.
///
/// A global notifier rather than a field on the screen, because the Settings
/// route is pushed *over* this one: nothing on the list rebuilds by itself when
/// the route pops, and a tab that vanished only on the next unrelated rebuild
/// would look like a glitch.
final ValueNotifier<Set<ContentKind>> visibleContentTabs =
    ValueNotifier<Set<ContentKind>>({...kContentSections});

/// The visible sections, in tab order.
List<ContentKind> visibleContentTabList() => [
  for (final kind in kContentSections)
    if (visibleContentTabs.value.contains(kind)) kind,
];

/// Reads the stored choice into [visibleContentTabs].
///
/// Runs before the first frame (see `main.dart`): the tab row's very existence
/// depends on it, so a late read would flash three tabs and then collapse them.
Future<void> loadVisibleContentTabs({AppSettingsStore? store}) async {
  final names = await (store ?? const AppSettingsStore()).visibleContentTabs();
  final kinds = {
    for (final kind in kContentSections)
      if (names.contains(kind.name)) kind,
  };
  visibleContentTabs.value = kinds.isEmpty ? {...kContentSections} : kinds;
}

/// Applies a choice from the settings screen: notifier first (the list redraws
/// at once), then the keychain.
Future<void> saveVisibleContentTabs(Set<ContentKind> kinds) async {
  if (kinds.isEmpty) return;
  final ordered = {
    for (final kind in kContentSections)
      if (kinds.contains(kind)) kind,
  };
  visibleContentTabs.value = ordered;
  await const AppSettingsStore().setVisibleContentTabs({
    for (final kind in ordered) kind.name,
  });
}
