import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/data/cloud_config.dart';
import 'package:iptvs/screens/connect_device_screen.dart';

void main() {
  group('pairingCodeFromScan', () {
    test('takes the code out of our own panel link', () {
      final link = pairingPanelLink('https://panel.iptvs.click/', 'ABCD2345');
      expect(link, contains('code=ABCD2345'));
      expect(pairingCodeFromScan(link), 'ABCD2345');
    });

    test('accepts a bare code, in any case, with surrounding spaces', () {
      expect(pairingCodeFromScan('  abcd2345 '), 'ABCD2345');
    });

    test('rejects what is not a code', () {
      expect(pairingCodeFromScan(''), isNull);
      expect(pairingCodeFromScan('https://panel.iptvs.click/'), isNull);
      expect(pairingCodeFromScan('https://example.test/?code='), isNull);
      // The server's alphabet has no 0/1/I/L/O.
      expect(pairingCodeFromScan('ABCD01IO'), isNull);
      expect(pairingCodeFromScan('hello world'), isNull);
    });
  });

  group('ConnectDeviceScreen', () {
    // Desktop posture: no camera, so the screen renders the typed-code path and
    // the tests never touch the platform scanner channel. The variant sets and
    // resets the platform override around each test body, which a manual
    // `debugDefaultTargetPlatformOverride` in `setUp` cannot do legally.
    final desktop = TargetPlatformVariant.only(TargetPlatform.windows);

    testWidgets('submits the typed code and reports success', (tester) async {
      String? claimed;
      final results = <bool?>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                results.add(
                  await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => ConnectDeviceScreen(
                        onClaim: (code) async => claimed = code,
                      ),
                    ),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'abcd2345');
      await tester.tap(find.text('Authorise this device'));
      await tester.pumpAndSettle();

      expect(claimed, 'ABCD2345');
      expect(results, [true]);
    }, variant: desktop);

    testWidgets('an expired code is explained, not echoed raw', (tester) async {
      var claimed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: ConnectDeviceScreen(
            onClaim: (code) async {
              claimed = true;
              throw Exception('invalid or expired code');
            },
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'ABCD2345');
      await tester.tap(find.text('Authorise this device'));
      await tester.pumpAndSettle();

      expect(find.textContaining('expired or was already used'), findsOneWidget);
      // The screen stays put: a failed claim must not pop the route.
      expect(find.text('Authorise this device'), findsOneWidget);
      expect(claimed, isTrue);
    }, variant: desktop);
  });
}
