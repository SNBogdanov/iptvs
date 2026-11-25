import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../data/cloud_config.dart';
import '../data/cloud_sync.dart';
import '../theme.dart';

/// Authorises **another** device (a freshly installed TV) from this one.
///
/// The TV shows a pairing code and its QR (`pairingPanelLink`); this screen
/// either scans that QR or takes the eight characters typed off the screen, and
/// claims the code through `claim_pairing_as_device` — the phone's own paired
/// session is the authority, so no panel login and no browser are involved.
///
/// Returns `true` through `Navigator.pop` once the code is claimed; the TV's
/// own `pairing_status` poll notices on its next tick and finishes by itself.
class ConnectDeviceScreen extends StatefulWidget {
  /// The client used to claim the code. Optional so a widget test can pass
  /// [onClaim] alone — constructing a real [CloudSync] needs an initialised
  /// Supabase instance, which those tests deliberately do not have.
  final CloudSync? sync;

  /// Overrides how a code is claimed. Defaults to
  /// [CloudSync.claimPairingAsDevice].
  final Future<void> Function(String code)? onClaim;

  const ConnectDeviceScreen({super.key, this.sync, this.onClaim})
    : assert(
        sync != null || onClaim != null,
        'pass a CloudSync, an onClaim callback, or both',
      );

  @override
  State<ConnectDeviceScreen> createState() => _ConnectDeviceScreenState();
}

class _ConnectDeviceScreenState extends State<ConnectDeviceScreen> {
  final TextEditingController _code = TextEditingController();
  MobileScannerController? _scanner;
  bool _busy = false;
  String? _error;

  /// A scan fires on every frame that still sees the QR. Only the first code is
  /// submitted, and the same code is not retried after a failure until the
  /// field changes — otherwise an expired code would hammer the RPC.
  String? _lastSubmitted;

  /// Cameras exist on phones; desktop and web builds get the code field only
  /// (the TV is across the room, the code is eight characters).
  bool get _canScan =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    if (_canScan) {
      _scanner = MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        // The same code seen twice is the same submission.
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
    }
  }

  @override
  void dispose() {
    _code.dispose();
    unawaited(_scanner?.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final code = pairingCodeFromScan(raw);
      if (code == null) continue;
      if (code == _lastSubmitted) return;
      unawaited(_submit(code));
      return;
    }
  }

  Future<void> _submit(String raw) async {
    final code = pairingCodeFromScan(raw) ?? raw.trim().toUpperCase();
    if (_busy || code.isEmpty) return;
    _lastSubmitted = code;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await (widget.onClaim ?? widget.sync!.claimPairingAsDevice)(code);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      _lastSubmitted = null;
      setState(() {
        _busy = false;
        _error = _messageFor(error);
      });
    }
  }

  /// The server's messages are written for a developer; these are the three the
  /// user can act on, and everything else is shown as-is rather than swallowed.
  String _messageFor(Object error) {
    final text = error.toString();
    if (text.contains('invalid or expired code')) {
      return 'That code has expired or was already used. Show a fresh one on '
          'the TV and try again.';
    }
    if (text.contains('only a paired device')) {
      return 'This device is not paired with a cloud account yet, so it cannot '
          'authorise another one.';
    }
    if (text.contains('cannot claim its own code')) {
      return 'That is this device\'s own code. Enter the code shown on the '
          'other device.';
    }
    return 'Could not authorise the device: $text';
  }

  @override
  Widget build(BuildContext context) {
    final scanner = _scanner;
    return Scaffold(
      backgroundColor: AppColors.ink,
      appBar: AppBar(
        title: const Text('Authorise a device'),
        backgroundColor: AppColors.panel,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'On the TV, open Cloud sync — it shows a code and a QR code. '
                  'Point this camera at the QR, or type the eight characters '
                  'below. This device\'s cloud account authorises the TV; no '
                  'panel login is needed.',
                  style: TextStyle(color: AppColors.textLo, height: 1.4),
                ),
                if (scanner != null) ...[
                  const SizedBox(height: 16),
                  AspectRatio(
                    aspectRatio: 4 / 3,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.control),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          MobileScanner(
                            controller: scanner,
                            onDetect: _onDetect,
                            errorBuilder: (context, error) => ColoredBox(
                              color: AppColors.panel,
                              child: Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(16),
                                  child: Text(
                                    'Camera unavailable — enter the code below.\n'
                                    '${error.errorCode.name}',
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: AppColors.textLo,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          // A plain frame: the scanner draws no chrome of its
                          // own, and an unframed camera preview reads as a
                          // broken video rather than as a viewfinder.
                          IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(
                                  AppRadius.control,
                                ),
                                border: Border.all(
                                  color: AppColors.accent,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Row(
                    children: [
                      Expanded(child: Divider(color: AppColors.line)),
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 12),
                        child: Text(
                          'or enter the code',
                          style: TextStyle(color: AppColors.textLo),
                        ),
                      ),
                      Expanded(child: Divider(color: AppColors.line)),
                    ],
                  ),
                ],
                const SizedBox(height: 16),
                TextField(
                  controller: _code,
                  autofocus: _scanner == null,
                  enabled: !_busy,
                  textCapitalization: TextCapitalization.characters,
                  style: const TextStyle(
                    fontSize: 22,
                    letterSpacing: 4,
                    fontWeight: FontWeight.w700,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]')),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Pairing code',
                    hintText: 'ABCD2345',
                  ),
                  onSubmitted: (value) => unawaited(_submit(value)),
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _busy ? null : () => unawaited(_submit(_code.text)),
                  icon: _busy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.link),
                  label: const Text('Authorise this device'),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 14),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 18,
                        color: AppColors.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          error,
                          style: const TextStyle(color: AppColors.danger),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
