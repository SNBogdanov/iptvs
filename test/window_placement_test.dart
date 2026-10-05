import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/app_settings_store.dart';
import 'package:iptvs/player/tray.dart' show kWindowsRunnerChannel;
import 'package:iptvs/player/window_placement.dart';

/// The placement feature has two halves that only agree by contract: Dart owns
/// the record (keychain) and the runner owns the HWND, exchanging a five-field
/// map. So these drive a real [AppSettingsStore] over the mocked keychain the
/// rest of the suite uses, and a mocked handler standing in for `flutter_window.cpp` —
/// stubbing either side out would only prove the code agrees with itself.
class _RunnerStub {
  _RunnerStub(this.channel);

  final MethodChannel channel;

  /// What `getWindowPlacement` answers; null models "no window yet".
  Object? reply;

  /// What `setWindowPlacement` is given, and whether the runner accepted it.
  Map<Object?, Object?>? lastArgs;
  bool? acceptPlacement = true;

  final List<String> calls = <String>[];

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      switch (call.method) {
        case 'getWindowPlacement':
          return reply;
        case 'setWindowPlacement':
          lastArgs = call.arguments as Map<Object?, Object?>?;
          return acceptPlacement;
        default:
          return null;
      }
    });
  }

  void dispose() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }

  bool applied(Map<String, Object> args) =>
      lastArgs?['x'] == args['x'] &&
      lastArgs?['y'] == args['y'] &&
      lastArgs?['width'] == args['width'] &&
      lastArgs?['height'] == args['height'] &&
      lastArgs?['maximized'] == args['maximized'];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RunnerStub runner;
  const channel = MethodChannel(kWindowsRunnerChannel);
  const store = AppSettingsStore();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    runner = _RunnerStub(channel);
    runner.install();
  });

  tearDown(() => runner.dispose());

  group('WindowPlacement encode/decode', () {
    test('round-trips every field', () {
      const original = WindowPlacement(
        x: -1440,
        y: 260,
        width: 1920,
        height: 1080,
        maximized: false,
      );
      expect(WindowPlacement.decode(original.encode()), original);
    });

    test('round-trips a maximized window on a negative origin', () {
      // A monitor left of the primary one reports a negative left/top, so the
      // sign is a normal value, not something to normalise away.
      const original = WindowPlacement(
        x: -1280,
        y: -200,
        width: 1280,
        height: 1024,
        maximized: true,
      );
      expect(WindowPlacement.decode(original.encode()), original);
    });

    test('rejects anything that is not this exact shape', () {
      // The alternative — restoring a window with the dimensions it happened to
      // parse and inventing the rest — is worse than opening where Windows puts
      // it, so every malformed record reads as "no record".
      for (final raw in <String?>[
        null,
        '',
        '1,2,3',
        '1,2,3,4,1,extra',
        'x,2,800,600,0',
        '1.5,2,800,600,0',
        '1,2,800,600',
        '1,2,800,600,yes',
      ]) {
        expect(WindowPlacement.decode(raw), isNull, reason: 'raw: "$raw"');
      }
    });

    test('rejects a size too small to be a window the user arranged', () {
      expect(
        WindowPlacement.decode('0,0,${WindowPlacement.minWidth - 1},600,0'),
        isNull,
      );
      expect(
        WindowPlacement.decode('0,0,800,${WindowPlacement.minHeight - 1},0'),
        isNull,
      );
    });

    test('accepts the minimum size', () {
      final decoded = WindowPlacement.decode(
        '0,0,${WindowPlacement.minWidth},${WindowPlacement.minHeight},0',
      );
      expect(decoded?.width, WindowPlacement.minWidth);
      expect(decoded?.height, WindowPlacement.minHeight);
      expect(decoded?.maximized, isFalse);
    });
  });

  group('WindowPlacement.fromRunner', () {
    test('reads the runner map', () {
      expect(
        WindowPlacement.fromRunner(<Object?, Object?>{
          'x': 120,
          'y': 64,
          'width': 1600,
          'height': 900,
          'maximized': true,
        }),
        const WindowPlacement(
          x: 120,
          y: 64,
          width: 1600,
          height: 900,
          maximized: true,
        ),
      );
    });

    test('a missing or unusable field is null, never defaulted', () {
      // A width of 0 means the call failed; completing it with a default would
      // be inventing a geometry the window never had.
      expect(WindowPlacement.fromRunner(<Object?, Object?>{}), isNull);
      expect(
        WindowPlacement.fromRunner(<Object?, Object?>{
          'x': 0,
          'y': 0,
          'width': 0,
          'height': 600,
        }),
        isNull,
      );
      expect(
        WindowPlacement.fromRunner(<Object?, Object?>{
          'x': 0,
          'y': 0,
          'width': 800,
          'height': 600,
          'maximized': 'true',
        }),
        isNull,
        reason: 'maximized must arrive as a real bool',
      );
    });
  });

  group('recordWindowPlacement', () {
    test('persists what the runner reports', () async {
      runner.reply = <Object?, Object?>{
        'x': 100,
        'y': 50,
        'width': 1280,
        'height': 800,
        'maximized': false,
      };

      await recordWindowPlacement(store: store, channel: channel);

      expect(await store.windowPlacement(), '100,50,1280,800,0');
    });

    test('a maximized window round-trips through the keychain', () async {
      runner.reply = <Object?, Object?>{
        'x': 0,
        'y': 0,
        'width': 2560,
        'height': 1440,
        'maximized': true,
      };

      await recordWindowPlacement(store: store, channel: channel);

      expect(await store.windowPlacement(), '0,0,2560,1440,1');
      expect((await readWindowPlacement(store: store))?.maximized, isTrue);
    });

    test('an unusable reply records nothing', () async {
      runner.reply = <Object?, Object?>{
        'x': 100,
        'y': 50,
        'width': 0,
        'height': 0,
      };

      await recordWindowPlacement(store: store, channel: channel);

      expect(await store.windowPlacement(), isNull);
    });

    test('a null reply (no window yet) records nothing', () async {
      runner.reply = null;

      await recordWindowPlacement(store: store, channel: channel);

      expect(await store.windowPlacement(), isNull);
      expect(runner.calls, contains('getWindowPlacement'));
    });

    test('the preference being off does not even ask the runner', () async {
      await store.setRememberWindowPlacement(false);
      runner.reply = <Object?, Object?>{
        'x': 0,
        'y': 0,
        'width': 1280,
        'height': 800,
      };

      await recordWindowPlacement(store: store, channel: channel);

      expect(runner.calls, isEmpty);
      expect(await store.windowPlacement(), isNull);
    });

    test('turning the preference off forgets the recorded geometry', () async {
      // Keeping a stale record the setting claims no longer applies is the kind
      // of thing that silently comes back when the setting is re-enabled.
      await store.setWindowPlacement('10,20,1280,800,0');
      await store.setRememberWindowPlacement(false);

      expect(await store.windowPlacement(), isNull);
    });

    test('the preference is on unless explicitly off', () async {
      expect(await store.rememberWindowPlacement(), isTrue);
      await store.setRememberWindowPlacement(false);
      expect(await store.rememberWindowPlacement(), isFalse);
      await store.setRememberWindowPlacement(true);
      expect(await store.rememberWindowPlacement(), isTrue);
    });
  });

  group('applySavedWindowPlacement', () {
    test('hands the recorded geometry to the runner', () async {
      await store.setWindowPlacement('40,80,1600,900,1');

      await applySavedWindowPlacement(store: store, channel: channel);

      expect(runner.calls, contains('setWindowPlacement'));
      expect(
        runner.applied(<String, Object>{
          'x': 40,
          'y': 80,
          'width': 1600,
          'height': 900,
          'maximized': true,
        }),
        isTrue,
      );
    });

    test('nothing recorded means nothing sent', () async {
      await applySavedWindowPlacement(store: store, channel: channel);

      expect(runner.calls, isEmpty);
    });

    test('a corrupt record is not forwarded to the runner', () async {
      await store.setWindowPlacement('garbage');

      await applySavedWindowPlacement(store: store, channel: channel);

      expect(runner.calls, isEmpty);
    });

    test('the preference being off suppresses a recorded geometry', () async {
      // The setting is the authority, not the record: a record that outlived
      // the toggle must still not be applied.
      const storage = FlutterSecureStorage();
      await storage.write(
        key: 'app_remember_window_placement',
        value: 'false',
      );
      await storage.write(key: 'app_window_placement', value: '40,80,1600,900,0');

      await applySavedWindowPlacement(store: store, channel: channel);

      expect(runner.calls, isEmpty);
    });

    test('a runner refusal completes quietly', () async {
      // The runner refuses when the saved monitor is gone; the window opens where
      // Windows decided, which is always better than off-screen. A throw here
      // would be an unhandled async error on the boot path.
      runner.acceptPlacement = false;
      await store.setWindowPlacement('40,80,1600,900,0');

      await expectLater(
        applySavedWindowPlacement(store: store, channel: channel),
        completes,
      );
      expect(runner.calls, contains('setWindowPlacement'));
    });
  });

  group('with no runner handler (off Windows, or a widget test)', () {
    setUp(() => runner.dispose());

    test('both directions complete instead of throwing', () async {
      await store.setWindowPlacement('40,80,1600,900,0');
      await expectLater(
        applySavedWindowPlacement(store: store, channel: channel),
        completes,
      );
      await expectLater(
        recordWindowPlacement(store: store, channel: channel),
        completes,
      );
    });
  });
}