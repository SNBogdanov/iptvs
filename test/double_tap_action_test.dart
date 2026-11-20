import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/player/double_tap_action.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const store = AppSettingsStore();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    doubleTapAction.value = DoubleTapAction.previousNext;
  });

  group('the choice', () {
    test('defaults to previous/next, which is also the absent key', () async {
      expect(DoubleTapAction.parse(null), DoubleTapAction.previousNext);
      expect(await store.rawDoubleTapAction(), isNull);
      expect(doubleTapAction.value, DoubleTapAction.previousNext);
    });

    test('round-trips both wire names', () {
      for (final value in DoubleTapAction.values) {
        expect(DoubleTapAction.parse(value.storageValue), value);
      }
      expect(DoubleTapAction.seek.storageValue, 'seek');
      expect(DoubleTapAction.previousNext.storageValue, 'prev_next');
    });

    test('an unknown value reads as the default', () {
      // A newer build may add a third action; this one must not go inert.
      expect(DoubleTapAction.parse('zoom'), DoubleTapAction.previousNext);
      expect(DoubleTapAction.parse(''), DoubleTapAction.previousNext);
    });

    test('the cycle is two-way and comes back', () {
      expect(DoubleTapAction.previousNext.other, DoubleTapAction.seek);
      expect(DoubleTapAction.seek.other, DoubleTapAction.previousNext);
    });
  });

  group('storage', () {
    test('seek persists, previous/next clears the key', () async {
      await setDoubleTapAction(DoubleTapAction.seek, store: store);
      expect(doubleTapAction.value, DoubleTapAction.seek);
      expect(await store.rawDoubleTapAction(), 'seek');

      await setDoubleTapAction(DoubleTapAction.previousNext, store: store);
      expect(await store.rawDoubleTapAction(), isNull);
      expect(doubleTapAction.value, DoubleTapAction.previousNext);
    });

    test('loads the stored value', () async {
      FlutterSecureStorage.setMockInitialValues({
        'app_double_tap_action': 'seek',
      });
      await loadDoubleTapAction(store: store);
      expect(doubleTapAction.value, DoubleTapAction.seek);
    });
  });
}
