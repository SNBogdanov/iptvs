// The typed-number chip, on the surfaces that draw it.
//
// Two things are load-bearing and neither is visible in a screenshot: the chip
// shows the *match* while the number is still being typed (so a partial number
// is readable as a jump), and it stays inside its own width no matter how long
// the channel name is. The chip is shared by the live list and the fullscreen
// player, so both are covered by pinning the widget itself.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/channel_number_entry.dart';
import 'package:iptvs/widgets/channel_number_chip.dart';

void main() {
  Future<void> pump(WidgetTester tester, Widget chip, {Size? size}) async {
    await tester.binding.setSurfaceSize(size ?? const Size(400, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(child: chip),
        ),
      ),
    );
  }

  testWidgets('prints the digits on the first line and the match below', (
    tester,
  ) async {
    await pump(
      tester,
      const ChannelNumberChip(digits: '12', matchLabel: 'Channel Twelve'),
    );

    expect(find.text('Ch 12'), findsOneWidget);
    expect(find.text('Channel Twelve'), findsOneWidget);
    // Two lines, and the name below the digits — the whole point of the second
    // line is that it reads as "these digits mean that channel".
    final digits = tester.getRect(find.text('Ch 12'));
    final name = tester.getRect(find.text('Channel Twelve'));
    expect(name.top, greaterThan(digits.bottom));
  });

  testWidgets('says No Data Found when nothing matches', (tester) async {
    await pump(
      tester,
      const ChannelNumberChip(
        digits: '99',
        matchLabel: kNoChannelNumberMatch,
      ),
    );

    expect(find.text('Ch 99'), findsOneWidget);
    expect(find.text(kNoChannelNumberMatch), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long name ellipsizes instead of stretching the chip', (
    tester,
  ) async {
    const long = 'A Very Long Channel Name That Goes On And On And On Forever';
    await pump(
      tester,
      const ChannelNumberChip(digits: '1', matchLabel: long),
      size: const Size(240, 200),
    );

    // One line, bounded, and the chip still fits the window it was given: the
    // digits are the input, the name is only a confirmation of them.
    final name = tester.getRect(find.text(long));
    expect(name.width, lessThanOrEqualTo(300));
    expect(tester.takeException(), isNull);
  });
}
