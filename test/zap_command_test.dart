import 'dart:io' show File;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/zap_command.dart';
import 'package:iptvs/player/zap_quick_list.dart';

void main() {
  group('parseZapCommand', () {
    test('parses every member of the vocabulary', () {
      expect(
        parseZapCommand('zap:up'),
        const ZapCommand(ZapCommandKind.channelUp),
      );
      expect(
        parseZapCommand('zap:down'),
        const ZapCommand(ZapCommandKind.channelDown),
      );
      expect(
        parseZapCommand('zap:prev'),
        const ZapCommand(ZapCommandKind.previousChannel),
      );
      expect(
        parseZapCommand('zap:list'),
        const ZapCommand(ZapCommandKind.openList),
      );
      expect(
        parseZapCommand('zap:close'),
        const ZapCommand(ZapCommandKind.closeList),
      );
      expect(
        parseZapCommand('zap:activate'),
        const ZapCommand(ZapCommandKind.activate),
      );
      expect(
        parseZapCommand('zap:back'),
        const ZapCommand(ZapCommandKind.back),
      );
      expect(
        parseZapCommand('zap:auto'),
        const ZapCommand(ZapCommandKind.autoSwitch),
      );
      expect(
        parseZapCommand('zap:digit:7'),
        const ZapCommand(ZapCommandKind.digit, 7),
      );
      expect(
        parseZapCommand('zap:move:-3'),
        const ZapCommand(ZapCommandKind.move, -3),
      );
      expect(
        parseZapCommand('favorite:1'),
        const ZapCommand(ZapCommandKind.favorite, 1),
      );
      expect(
        parseZapCommand('favorite:0'),
        const ZapCommand(ZapCommandKind.favorite, 0),
      );
    });

    test('a command it cannot read is dropped, never guessed at', () {
      // A surface that sends nonsense must not move the cursor: the natives
      // hold no list, so a mis-parse is unrecoverable from their side.
      expect(parseZapCommand(null), isNull);
      expect(parseZapCommand(''), isNull);
      expect(parseZapCommand('zap'), isNull);
      expect(parseZapCommand('zap:'), isNull);
      expect(parseZapCommand('zap:sideways'), isNull);
      expect(parseZapCommand('zap:digit:'), isNull);
      expect(parseZapCommand('zap:digit:x'), isNull);
      expect(parseZapCommand('zap:digit:12'), isNull);
      expect(parseZapCommand('zap:digit:-1'), isNull);
      expect(parseZapCommand('zap:move:'), isNull);
      expect(parseZapCommand('zap:move:0'), isNull);
      expect(parseZapCommand('favorite:'), isNull);
      expect(parseZapCommand('favorite:2'), isNull);
    });

    test('leaves the pre-existing control vocabulary alone', () {
      // The Windows overlay funnels both through one inbound method, so a
      // zap parser that claimed these would silently break the control row.
      for (final command in const [
        'back',
        'playPause',
        'goLive',
        'favorite',
        'aspect',
        'info',
        'menu:audio',
        'speed:1.5',
        'seekPercent:0.5',
        'volumePercent:0.25',
      ]) {
        expect(parseZapCommand(command), isNull, reason: command);
      }
    });
  });

  group('digit entry constants', () {
    test('cover both the number row and the numpad', () {
      for (var digit = 0; digit <= 9; digit++) {
        expect(
          kDigitEntryKeys[LogicalKeyboardKey(
            LogicalKeyboardKey.digit0.keyId + digit,
          )],
          digit,
        );
      }
      expect(kDigitEntryKeys[LogicalKeyboardKey.numpad0], 0);
      expect(kDigitEntryKeys[LogicalKeyboardKey.numpad9], 9);
      expect(kDigitEntryKeys.length, 20);
    });

    test('bound so a channel number is neither cut short nor open-ended', () {
      expect(kDigitEntryMaxDigits, 4);
      expect(kDigitEntryCommitDelay, const Duration(milliseconds: 1500));
    });
  });

  group('ZapResolveGate', () {
    test('admits one request at a time', () {
      final gate = ZapResolveGate();
      final first = gate.begin();
      expect(first, isNotNull);
      expect(gate.inFlight, isTrue);
      expect(gate.begin(), isNull);
      expect(gate.settle(first!), isTrue);
      expect(gate.inFlight, isFalse);
    });

    test('settles exactly once, and never for a superseded token', () {
      final gate = ZapResolveGate();
      final first = gate.begin()!;
      expect(gate.settle(first), isTrue);
      expect(gate.settle(first), isFalse);
      final second = gate.begin()!;
      // The first request's late reply must not settle the second.
      expect(gate.settle(first), isFalse);
      expect(gate.settle(second), isTrue);
    });

    test('abandon drops the in-flight request without settling it', () {
      // A zap supersedes a reconnect re-resolve outright: that reply describes
      // the channel the user has left, and applying it would reload it.
      final gate = ZapResolveGate();
      final stale = gate.begin()!;
      gate.abandon();
      expect(gate.inFlight, isFalse);
      final fresh = gate.begin();
      expect(fresh, isNotNull);
      expect(gate.settle(stale), isFalse);
      expect(gate.settle(fresh!), isTrue);
    });
  });

  group('ZapDebounce', () {
    test('runs the last scheduled action once, after the delay', () async {
      final debounce = ZapDebounce();
      final ran = <String>[];
      debounce.schedule(
        const Duration(milliseconds: 5),
        () => ran.add('first'),
      );
      debounce.schedule(
        const Duration(milliseconds: 5),
        () => ran.add('second'),
      );
      expect(debounce.pending, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(ran, ['second']);
      expect(debounce.pending, isFalse);
    });

    test('flush commits early and cancel drops it', () async {
      final debounce = ZapDebounce();
      var ran = 0;
      debounce.schedule(const Duration(seconds: 10), () => ran++);
      debounce.flush();
      expect(ran, 1);
      debounce.flush(); // nothing pending any more
      expect(ran, 1);

      debounce.schedule(const Duration(milliseconds: 5), () => ran++);
      debounce.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(ran, 1);
    });
  });

  // A page key's step is duplicated in four places by necessity — the natives
  // cannot import Dart — and there is no test anywhere that would notice one of
  // them drifting. So the duplication gets its own assertion, which is what
  // keeps "Page Down moves a pageful" one behaviour rather than four.
  group('quick-list mouse', () {
    test('wheel delta is three rows per notch, signed by direction', () {
      expect(kZapWheelRows, 3);
      expect(zapQuickListWheelDelta(120), kZapWheelRows);
      expect(zapQuickListWheelDelta(1), kZapWheelRows);
      expect(zapQuickListWheelDelta(-120), -kZapWheelRows);
      expect(zapQuickListWheelDelta(-0.5), -kZapWheelRows);
      // A horizontal scroll arrives as a zero `dy`, and a zero is ignored
      // rather than rounded into a row - guessing a direction is how a
      // gesture ends up moving the cursor sideways.
      expect(zapQuickListWheelDelta(0), 0);
    });

    test('the Windows renderer mirrors the same step', () {
      // The natives speak only `zap:move:<n>`, so a step that differs per
      // surface makes one notch of the wheel travel a different distance
      // depending on which renderer is drawing.
      final file = File('windows/runner/zap_quick_list_state.h');
      expect(file.existsSync(), isTrue);
      final declared = RegExp(
        r'kNativeWheelRows\s*=\s*(\d+)',
      ).firstMatch(file.readAsStringSync());
      expect(
        declared?.group(1),
        '$kZapWheelRows',
        reason: 'the native wheel step is ${declared?.group(1)}, '
            'but Dart moves the cursor by $kZapWheelRows',
      );
    });

    test('a row click moves the cursor onto that row, or not at all', () {
      // One click has to both put the cursor on the row and play it, so the
      // delta is absolute-index-minus-cursor: 0 means "already there", and the
      // press then only has to activate. A row outside the pushed window is
      // not clickable - there is no row drawn there to click.
      final state = ZapQuickListState(
        open: true,
        mode: ZapQuickListMode.channels,
        heading: 'All channels',
        rows: const [
          ZapQuickListRow(index: 10, id: 'a', label: 'a', kind: ZapQuickListRowKind.channel),
          ZapQuickListRow(index: 11, id: 'b', label: 'b', kind: ZapQuickListRowKind.channel),
          ZapQuickListRow(index: 12, id: 'c', label: 'c', kind: ZapQuickListRowKind.channel),
        ],
        selectedIndex: 4,
        windowStart: 10,
        total: 3,
      );
      // Positive is down the list, which is what `moveQuickList` means by it.
      expect(zapQuickListRowMoveDelta(state, 0), 6);
      expect(zapQuickListRowMoveDelta(state, 1), 7);
      expect(zapQuickListRowMoveDelta(state, 2), 8);
      expect(zapQuickListRowMoveDelta(state, -1), 0);
      expect(zapQuickListRowMoveDelta(state, 3), 0);
    });
  });

  group('quick-list page step', () {
    test('is the window less one row, so pages overlap by a row', () {
      // A whole-window jump would leave no overlap, so a scan of consecutive
      // pages appears to skip content between pages.
      expect(kZapPageRows, kZapWindowRows - 1);
      expect(kZapPageRows, greaterThan(0));
    });

    test('every native surface hardcodes the same step', () {
      // `zap:move:<n>` is the only thing the natives send; if one of them
      // disagrees with the others a page key means a different distance
      // depending on which surface is drawing.
      final surfaces = <String, String>{
        'windows/runner/zap_key_policy.h': 'kZapPageRows',
        'android/app/src/main/kotlin/com/gchofficial/iptvs/player/ZapKeyPolicy.kt':
            'ZAP_PAGE_ROWS',
        'linux/mpv/iptvs_overlay.lua': 'ZAP_PAGE_ROWS',
      };
      surfaces.forEach((path, name) {
        final file = File(path);
        expect(
          file.existsSync(),
          isTrue,
          reason: '$path must keep the page step mirrored from Dart',
        );
        // Matched on the name alone: the three languages spell the declaration
        // differently (`int x = 39`, `const val x = 39`, `local x = 39`) and a
        // pattern that tried to cover all of them would stop matching the day
        // one of them reorders its keywords.
        final declared = RegExp(
          name + r'\s*=\s*(\d+)',
        ).firstMatch(file.readAsStringSync());
        expect(
          declared?.group(1),
          '$kZapPageRows',
          reason: '$path declares $name as ${declared?.group(1)}, '
              'but Dart pages by $kZapPageRows',
        );
      });
    });

    test('parses as an ordinary signed move on every delta', () {
      // The natives' page commands must survive the shared parser, which is
      // what routes them to `moveQuickList` and not to a channel switch.
      expect(
        parseZapCommand('zap:move:$kZapPageRows'),
        ZapCommand(ZapCommandKind.move, kZapPageRows),
      );
      expect(
        parseZapCommand('zap:move:-39'),
        const ZapCommand(ZapCommandKind.move, -39),
      );
    });
  });
}
