import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/app_settings_store.dart';
import '../data/diagnostics_log.dart';
import 'tray.dart';

/// The window's last position and size, in the physical pixels of its frame
/// rectangle (which is the space `SetWindowPos` and `GetWindowRect` speak).
///
/// Dart owns this because the keychain is Dart's, and the runner owns the
/// HWND: the two ends are [readWindowPlacement] / [recordWindowPlacement] here
/// and `getWindowPlacement` / `setWindowPlacement` in `flutter_window.cpp`.
///
/// Stored as `x,y,width,height,maximized` rather than JSON because there is no
/// preference file to be pretty: it is one keychain value read once at boot and
/// written when the window goes away.
@immutable
class WindowPlacement {
  final int x;
  final int y;
  final int width;
  final int height;
  final bool maximized;

  const WindowPlacement({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.maximized,
  });

  /// Below this a window is not usable, and a record this small is a corrupt one
  /// rather than something a user arranged. The runner refuses the same values,
  /// so a hand-edited keychain cannot produce an unresizable window either.
  static const int minWidth = 320;
  static const int minHeight = 240;

  static const String _separator = ',';

  /// Builds a placement from the runner's `getWindowPlacement` map, or null when
  /// a field is missing or the size is unusable. A partial read is not completed
  /// with defaults: a width of 0 means the call failed, and restoring a window
  /// from it would be inventing geometry.
  static WindowPlacement? fromRunner(Map<Object?, Object?> map) {
    int? field(String key) {
      final value = map[key];
      return value is int ? value : null;
    }

    final x = field('x');
    final y = field('y');
    final width = field('width');
    final height = field('height');
    // `maximized` is required, and required to be a bool: it chooses between
    // SW_MAXIMIZE and an explicit rectangle, so reading a corrupted value as
    // `false` would open a maximized window as a resizable one occupying the
    // maximized rect - silently the wrong answer rather than a refused one.
    final maximized = map['maximized'];
    if (x == null ||
        y == null ||
        width == null ||
        height == null ||
        width < minWidth ||
        height < minHeight ||
        maximized is! bool) {
      return null;
    }
    return WindowPlacement(
      x: x,
      y: y,
      width: width,
      height: height,
      maximized: maximized,
    );
  }

  String encode() => <Object>[
        x,
        y,
        width,
        height,
        maximized ? 1 : 0,
      ].join(_separator);

  /// Parses [raw], or null when it is absent or anything but exactly this
  /// shape.
  ///
  /// A record that cannot be read is discarded rather than half-applied: the
  /// alternative is restoring a window at some position with some of the
  /// dimensions, which is worse than letting the runner's own startup placement
  /// stand.
  static WindowPlacement? decode(String? raw) {
    if (raw == null) return null;
    final parts = raw.split(_separator);
    if (parts.length != 5) return null;
    final numbers = <int>[];
    for (final part in parts.take(4)) {
      final value = int.tryParse(part.trim());
      if (value == null) return null;
      numbers.add(value);
    }
    if (numbers[2] < minWidth || numbers[3] < minHeight) return null;
    final flag = parts[4].trim();
    if (flag != '0' && flag != '1') return null;
    return WindowPlacement(
      x: numbers[0],
      y: numbers[1],
      width: numbers[2],
      height: numbers[3],
      maximized: flag == '1',
    );
  }

  /// The map the runner's `setWindowPlacement` reads. Dart ints arrive as
  /// int64 on the C++ side, which is what it looks for.
  Map<String, Object> get runnerArguments => <String, Object>{
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'maximized': maximized,
      };

  @override
  bool operator ==(Object other) =>
      other is WindowPlacement &&
      other.x == x &&
      other.y == y &&
      other.width == width &&
      other.height == height &&
      other.maximized == maximized;

  @override
  int get hashCode => Object.hash(x, y, width, height, maximized);

  @override
  String toString() =>
      'WindowPlacement($x, $y, ${width}x$height, maximized: $maximized)';
}

/// Reads the recorded placement, or null when there is none to read.
Future<WindowPlacement?> readWindowPlacement({AppSettingsStore? store}) async {
  final settings = store ?? const AppSettingsStore();
  if (!await settings.rememberWindowPlacement()) return null;
  return WindowPlacement.decode(await settings.windowPlacement());
}

/// Asks the runner where the window is and records it.
///
/// Silently does nothing when the preference is off, or off Windows, or when the
/// runner has no handler: in every one of those cases there is nowhere to record
/// to, and a window geometry is not worth an error the user can see.
Future<void> recordWindowPlacement({
  AppSettingsStore? store,
  MethodChannel? channel,
}) async {
  final settings = store ?? const AppSettingsStore();
  if (!await settings.rememberWindowPlacement()) return;
  final method = channel ?? const MethodChannel(kWindowsRunnerChannel);
  try {
    final raw = await method.invokeMapMethod<Object?, Object?>(
      'getWindowPlacement',
    );
    if (raw == null) return;
    final placement = WindowPlacement.fromRunner(raw);
    if (placement == null) return;
    await settings.setWindowPlacement(placement.encode());
  } on MissingPluginException {
    // Not Windows (or a widget test): nothing to record against.
  } on PlatformException catch (e) {
    DiagnosticsLog.instance.add(
      'player',
      'window placement record failed: ${e.code}',
    );
  }
}

/// Hands the recorded placement to the runner, if there is one.
///
/// A `false` answer means the runner refused it - the saved monitor is gone, or
/// the rectangle is unusable - and the runner's own startup placement stands.
/// That is a normal outcome, not a failure to report: a window that opens where
/// Windows decided is always better than one restored off-screen.
Future<void> applySavedWindowPlacement({
  AppSettingsStore? store,
  MethodChannel? channel,
}) async {
  final placement = await readWindowPlacement(store: store);
  if (placement == null) return;
  final method = channel ?? const MethodChannel(kWindowsRunnerChannel);
  try {
    final applied = await method.invokeMethod<bool>(
      'setWindowPlacement',
      placement.runnerArguments,
    );
    if (applied != true) {
      DiagnosticsLog.instance.add(
        'player',
        'saved window placement refused by the runner (monitor gone?) - '
        'keeping the startup position',
      );
    }
  } on MissingPluginException {
    // No runner handler on this platform (or in a test).
  } on PlatformException catch (e) {
    DiagnosticsLog.instance.add(
      'player',
      'window placement apply failed: ${e.code}',
    );
  }
}

/// Applies the saved placement and starts recording it.
///
/// Recording is driven by *moments*, not by `WM_MOVE`: a keychain write per drag
/// frame is not a cost worth paying, and the two moments that matter are the ones
/// where the geometry is about to stop being observable - the window hiding to
/// the tray, and the app going away. A write that repeats an identical value is
/// harmless, so a redundant trigger costs nothing while a missed one is the bug.
void startWindowPlacementTracking() {
  unawaited(applySavedWindowPlacement());
  silenceRequest.addListener(() => unawaited(recordWindowPlacement()));
  WidgetsBinding.instance.addObserver(_PlacementLifecycleObserver());
}

/// The Windows `hidden` lifecycle does not fire for a `SW_HIDE` (the engine
/// keeps the child view in its visible-windows set), which is why the tray hide
/// goes through [silenceRequest] instead; `paused`/`detached` cover the real
/// quit paths that do reach Dart.
class _PlacementLifecycleObserver extends WidgetsBindingObserver {
  _PlacementLifecycleObserver();

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(recordWindowPlacement());
    }
  }
}