import 'package:flutter_test/flutter_test.dart';
import 'package:iptvs/player/buffer_preset.dart';
import 'package:iptvs/player/mpv_options.dart';

/// mpv log levels from quietest to loudest. `no` is mpv's own "log nothing"
/// level, which is why it heads the list rather than trailing it.
const List<String> _rank = [
  'no',
  'fatal',
  'error',
  'warn',
  'info',
  'v',
  'debug',
  'trace',
];

/// The `msg-level` value as a `module -> level` map, so the assertions read like
/// the thing they pin rather than doing string surgery on a comma list.
Map<String, String> _levels() {
  final raw = kMpvLogFilter['msg-level'];
  expect(raw, isNotNull, reason: 'kMpvLogFilter lost its msg-level entry');
  final out = <String, String>{};
  for (final part in raw!.split(',')) {
    final bits = part.split('=');
    expect(bits, hasLength(2), reason: 'malformed msg-level entry: $part');
    out[bits[0]] = bits[1];
  }
  return out;
}

void main() {
  group('kMpvLogFilter', () {
    test("keeps mpv's own messages at warn, unchanged", () {
      // Both PlayerConfiguration sites set `logLevel: MPVLogLevel.warn`, and
      // setting `msg-level` after init replaces media_kit's
      // `mpv_request_log_messages(ctx, 'warn')` call wholesale rather than
      // adding to it — so `all` has to restate that level, or the filter would
      // quietly raise mpv's own verbosity while lowering FFmpeg's.
      expect(_levels()['all'], 'warn');
    });

    test('never drops the ffmpeg module below error', () {
      // media_kit consumes error-level log messages internally to populate its
      // `errorController`, which is what surfaces a playback failure to the
      // error/reconnect path. `fatal`/`no` here would silence the messages
      // recovery depends on. The missing-entry case matters just as much:
      // without an explicit `ffmpeg=` the module inherits the global level and
      // the provider spam comes straight back.
      final ffmpeg = _levels()['ffmpeg'];
      expect(ffmpeg, isNotNull, reason: 'no ffmpeg= entry: provider spam returns');
      expect(_rank, contains(ffmpeg), reason: 'unknown mpv log level: $ffmpeg');
      expect(
        _rank.indexOf(ffmpeg!),
        lessThanOrEqualTo(_rank.indexOf('error')),
        reason: 'ffmpeg=$ffmpeg is quieter than error; errorController starves',
      );
    });

    test('collides with no other option map merged alongside it', () {
      // `_configureNativePlayer` and `LivePreviewController._createPlayer` merge
      // several maps into a single `applyMpvOptions` call. A shared key means the
      // filter is silently dropped — or applied — depending on spread order.
      for (final key in kMpvLogFilter.keys) {
        expect(
          kLiveMpvOptions.containsKey(key),
          isFalse,
          reason: 'kMpvLogFilter overrides kLiveMpvOptions["$key"]',
        );
        for (final preset in BufferPreset.values) {
          expect(
            mpvBufferOptions(preset).containsKey(key),
            isFalse,
            reason: '$preset overrides kMpvLogFilter["$key"]',
          );
        }
      }
    });
  });
}
