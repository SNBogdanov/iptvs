// CloudAutoSync: the debounce/coalesce/retry behaviour that decides how often
// an auto-pushing device talks to the server, and whether a change can be lost.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:iptvs/data/cloud_auto_sync.dart';

void main() {
  late StreamController<void> changes;
  late int pulls;
  late int pushes;

  setUp(() {
    changes = StreamController<void>.broadcast();
    pulls = 0;
    pushes = 0;
  });

  tearDown(() => changes.close());

  CloudAutoSync build({
    Future<void> Function()? pull,
    Future<bool> Function()? push,
    Duration debounce = const Duration(seconds: 5),
    Duration retryDelay = const Duration(seconds: 30),
    Duration? ticketExtend,
    Stream<void>? flushRequests,
  }) => CloudAutoSync(
    pull: pull ?? () async => pulls++,
    push:
        push ??
        () async {
          pushes++;
          return true;
        },
    changes: changes.stream,
    flushRequests: flushRequests,
    debounce: debounce,
    ticketExtend: ticketExtend,
    retryDelay: retryDelay,
  );

  test('start pulls once, then pushes anything already queued', () {
    fakeAsync((async) {
      final sync = build();
      sync.start();
      async.flushMicrotasks();
      expect(pulls, 1);

      // The trailing push is debounced, not immediate.
      expect(pushes, 0);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1);
      sync.dispose();
    });
  });

  test('several rapid changes coalesce into one push', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      for (var i = 0; i < 5; i++) {
        changes.add(null);
        async.elapse(const Duration(milliseconds: 200));
      }
      async.flushMicrotasks();
      // Still inside the debounce window: nothing sent yet.
      expect(pushes, 0);

      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'five toggles is one round trip, not five');
      sync.dispose();
    });
  });

  test('a change during an in-flight push is not lost', () {
    fakeAsync((async) {
      final completers = <Completer<bool>>[];
      final sync = build(
        push: () {
          pushes++;
          final c = Completer<bool>();
          completers.add(c);
          return c.future;
        },
      );
      sync.start(pullFirst: false);
      async.flushMicrotasks();

      changes.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 1);

      // Toggled while the first push is still in flight.
      changes.add(null);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'no second push stacked behind the first');

      completers.first.complete(true);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(pushes, 2, reason: 'the change made mid-push is sent afterwards');
      sync.dispose();
    });
  });

  test('a failed push retries and does not throw', () {
    fakeAsync((async) {
      var attempts = 0;
      final sync = build(
        push: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return true;
        },
        retryDelay: const Duration(seconds: 30),
      );
      sync.start(pullFirst: false);
      async.flushMicrotasks();

      changes.add(null);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      expect(attempts, 1);

      async.elapse(const Duration(seconds: 30));
      async.flushMicrotasks();
      expect(attempts, 2, reason: 'the queued change is retried');
      sync.dispose();
    });
  });

  test('a failing pull never propagates to the caller', () {
    fakeAsync((async) {
      final sync = build(pull: () async => throw StateError('no network'));
      // start() awaits pullNow(); an unswallowed throw here would take the app
      // launch (or a profile switch) down with it.
      var completed = false;
      sync.start().then((_) => completed = true);
      async.flushMicrotasks();
      expect(completed, isTrue);
      sync.dispose();
    });
  });

  test('flush bypasses the debounce', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      changes.add(null);
      async.elapse(const Duration(milliseconds: 100));
      sync.flush();
      async.flushMicrotasks();
      expect(pushes, 1, reason: 'backgrounding must not wait out the timer');
      sync.dispose();
    });
  });

  test('nothing fires after dispose', () {
    fakeAsync((async) {
      final sync = build();
      sync.start(pullFirst: false);
      async.flushMicrotasks();
      pushes = 0;

      changes.add(null);
      sync.dispose();
      async.elapse(const Duration(minutes: 5));
      async.flushMicrotasks();
      expect(pushes, 0);
    });
  });

  group('ticket mode (watch state)', () {
    // A player writes a position every 30 s while something plays. The ticket is
    // set 30 s out on the first change and each later change moves it only 1 s,
    // so the push happens shortly after the first unsent change instead of
    // waiting for playback to stop (a plain debounce restarts on every write and
    // would never fire).

    test('the first ticket comes due 30 s after start', () {
      fakeAsync((async) {
        final sync = build(
          debounce: const Duration(seconds: 30),
          ticketExtend: const Duration(seconds: 1),
        );
        sync.start(pullFirst: false);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 29));
        async.flushMicrotasks();
        expect(pushes, 0);

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(pushes, 1);
        sync.dispose();
      });
    });

    test('a write slides the ticket one second, not the whole window', () {
      fakeAsync((async) {
        final sync = build(
          debounce: const Duration(seconds: 30),
          ticketExtend: const Duration(seconds: 1),
        );
        sync.start(pullFirst: false);
        async.flushMicrotasks();

        changes.add(null);
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(
          pushes,
          0,
          reason: 'the ticket moved to 31 s; a restart would be 60 s away',
        );

        async.elapse(const Duration(seconds: 1));
        async.flushMicrotasks();
        expect(pushes, 1);
        sync.dispose();
      });
    });

    test('a stream of writes slides the ticket, which still comes due', () {
      fakeAsync((async) {
        final sync = build(
          debounce: const Duration(seconds: 30),
          ticketExtend: const Duration(seconds: 1),
        );
        sync.start(pullFirst: false);
        async.flushMicrotasks();

        // Six writes over 25 s: the ticket is 30 + 6 = 36 s after start.
        for (var i = 0; i < 6; i++) {
          changes.add(null);
          async.elapse(const Duration(seconds: 5));
          async.flushMicrotasks();
        }
        async.elapse(const Duration(seconds: 4));
        async.flushMicrotasks();
        expect(pushes, 0, reason: 'at 34 s the ticket is still ahead');

        async.elapse(const Duration(seconds: 2));
        async.flushMicrotasks();
        expect(pushes, 1, reason: 'the ticket eventually comes due');
        sync.dispose();
      });
    });

    test('a stop request flushes without waiting out the ticket', () {
      fakeAsync((async) {
        final flush = StreamController<void>.broadcast();
        final sync = build(
          debounce: const Duration(seconds: 30),
          ticketExtend: const Duration(seconds: 1),
          flushRequests: flush.stream,
        );
        sync.start(pullFirst: false);
        async.flushMicrotasks();
        pushes = 0;

        changes.add(null);
        async.elapse(const Duration(seconds: 2));
        flush.add(null);
        async.flushMicrotasks();
        expect(pushes, 1, reason: 'closing the player sends what is queued');
        flush.close();
        sync.dispose();
      });
    });

    test('a flush during an in-flight push is not swallowed', () {
      fakeAsync((async) {
        final completers = <Completer<bool>>[];
        final sync = build(
          debounce: const Duration(seconds: 30),
          ticketExtend: const Duration(seconds: 1),
          push: () {
            pushes++;
            final c = Completer<bool>();
            completers.add(c);
            return c.future;
          },
        );
        sync.start(pullFirst: false);
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(pushes, 1);

        sync.flush();
        async.flushMicrotasks();
        expect(pushes, 1, reason: 'nothing is stacked behind the first push');

        completers.first.complete(true);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(pushes, 2);
        sync.dispose();
      });
    });
  });
}
