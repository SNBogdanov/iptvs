// The channel list's section choice: which of Live / Movies / Series exist.
//
// The rule that matters is "never zero": a preference that hid every section
// would leave the list with nothing to show and no tab row to bring one back.
// The store reads an empty or unreadable value back as all three, and the
// notifier refuses an empty set.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/data/content_tabs_visibility.dart';
import 'package:iptvs/sources/source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = AppSettingsStore();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    visibleContentTabs.value = {...kContentSections};
  });

  test('an untouched install shows every section', () async {
    await loadVisibleContentTabs(store: store);
    expect(visibleContentTabs.value, containsAll(kContentSections));
    expect(await store.visibleContentTabs(), hasLength(3));
  });

  test(
    'a hidden section is stored, and read back without the others',
    () async {
      await saveVisibleContentTabs({ContentKind.movie});
      expect(visibleContentTabs.value, {ContentKind.movie});
      expect(visibleContentTabList(), [ContentKind.movie]);

      // A fresh read (another launch) sees the same choice.
      visibleContentTabs.value = {...kContentSections};
      await loadVisibleContentTabs(store: store);
      expect(visibleContentTabs.value, {ContentKind.movie});
    },
  );

  test('turning one back on adds it to the stored set', () async {
    await saveVisibleContentTabs({ContentKind.movie});
    await saveVisibleContentTabs({ContentKind.movie, ContentKind.series});
    expect(visibleContentTabList(), [ContentKind.movie, ContentKind.series]);
  });

  test('all three is stored as the default, not as a value', () async {
    await saveVisibleContentTabs({ContentKind.movie});
    await saveVisibleContentTabs({...kContentSections});
    expect(visibleContentTabs.value, containsAll(kContentSections));
    // Absence is the default: a fresh install and a "show everything" choice
    // are the same state.
    expect(await store.visibleContentTabs(), hasLength(3));
    FlutterSecureStorage.setMockInitialValues({});
    expect(await store.visibleContentTabs(), hasLength(3));
  });

  test('an empty set is refused rather than leaving no content', () async {
    await saveVisibleContentTabs({ContentKind.series});
    await saveVisibleContentTabs({});
    expect(visibleContentTabs.value, {ContentKind.series});
  });

  test(
    'an unknown stored name is ignored, and an empty value means all',
    () async {
      FlutterSecureStorage.setMockInitialValues({
        'app_visible_content_tabs': 'movie,from_a_newer_build',
      });
      await loadVisibleContentTabs(store: store);
      expect(visibleContentTabs.value, {ContentKind.movie});

      FlutterSecureStorage.setMockInitialValues({
        'app_visible_content_tabs': '',
      });
      await loadVisibleContentTabs(store: store);
      expect(visibleContentTabs.value, containsAll(kContentSections));
    },
  );
}
