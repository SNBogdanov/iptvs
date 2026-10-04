import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/tray.dart';

/// The runner window-style settings are pushed from paths that run
/// unconditionally on Windows — the boot-time preference push, and the
/// always-on-top sync's post-frame callback — so "the handler isn't there" is a
/// normal state, not an error. It was not: the always-on-top sync's
/// `MissingPluginException` escaped unhandled and broke a widget test that
/// merely mounted the channel list.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(kWindowsRunnerChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  void handleWith(Future<Object?>? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(channel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('with a runner listening', () {
    setUp(() => handleWith((_) async => null));

    test('applyAlwaysOnTop sends the method and the flag', () async {
      await applyAlwaysOnTop(true);
      await applyAlwaysOnTop(false);

      expect(calls.map((c) => c.method), ['setAlwaysOnTop', 'setAlwaysOnTop']);
      expect(calls.map((c) => c.arguments), [true, false]);
    });

    test('applyCloseToTray sends the method and the flag', () async {
      await applyCloseToTray(false);

      expect(calls.single.method, 'setCloseToTray');
      expect(calls.single.arguments, isFalse);
    });
  });

  group('with no runner handler at all', () {
    setUp(() => messenger.setMockMethodCallHandler(channel, null));

    test('both settings complete instead of throwing', () async {
      // The documented no-op, actually pinned. Off Windows this channel has no
      // handler for these two methods, and neither does a widget test.
      await expectLater(applyAlwaysOnTop(true), completes);
      await expectLater(applyCloseToTray(false), completes);
    });
  });

  group('with a runner that fails the call', () {
    setUp(
      () => handleWith((_) async => throw PlatformException(code: 'EPERM')),
    );

    test('a PlatformException is logged, not thrown', () async {
      // A broken runner must not turn into an unhandled async error either:
      // the preference is already persisted, so retrying every mount would be
      // the only way to fix it and that is not this call site's business.
      await expectLater(applyAlwaysOnTop(true), completes);
      expect(calls.single.method, 'setAlwaysOnTop');
    });
  });
}
