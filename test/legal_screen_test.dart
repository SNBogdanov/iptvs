import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/screens/legal_screen.dart';
import 'package:iptvs/widgets/focusable_card.dart';

void main() {
  testWidgets('exposes support, source, privacy, and cloud deletion paths', (
    tester,
  ) async {
    // Tall enough that every link card is built: a lazy ListView only builds what
    // its viewport shows, and this screen now has five links.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));
    await tester.pump();

    expect(find.text('Help & about'), findsOneWidget);

    // Every link is a D-pad-navigable FocusableCard with a real handler, so a
    // TV remote can reach and activate it.
    for (final label in const [
      'Support',
      'This fork on GitHub',
      'Original project',
      'Privacy policy',
      'Delete cloud account',
    ]) {
      expect(find.text(label), findsOneWidget);
      final card = tester.widget<FocusableCard>(
        find.ancestor(
          of: find.text(label),
          matching: find.byType(FocusableCard),
        ),
      );
      expect(card.onTap, isNotNull);
    }
  });

  testWidgets('first link autofocuses so a D-pad user lands on a focus ring', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));
    await tester.pump();

    final firstCard = tester.widget<FocusableCard>(
      find.ancestor(
        of: find.text('Support'),
        matching: find.byType(FocusableCard),
      ),
    );
    expect(firstCard.autofocus, isTrue);
  });

  testWidgets('a development build offers the published release', (
    tester,
  ) async {
    // The suite builds without DISTRIBUTION_CHANNEL, i.e. as a development
    // build — exactly the channel that has no updater of its own and needs the
    // explicit way back to a release.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: LegalScreen()));
    await tester.pump();

    expect(find.text('Updates'), findsOneWidget);
    expect(find.text('This is a development build'), findsOneWidget);
    final card = tester.widget<FocusableCard>(
      find.ancestor(
        of: find.text('This is a development build'),
        matching: find.byType(FocusableCard),
      ),
    );
    expect(card.onTap, isNotNull);
    // A development build has no update track or manual check: both belong to
    // the direct updater.
    expect(find.text('Check for updates'), findsNothing);
    expect(find.text('GitHub update track'), findsNothing);
  });
}
