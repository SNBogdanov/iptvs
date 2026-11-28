import 'dart:async';
import 'dart:io' show Platform, Process, exit;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'package:url_launcher/url_launcher.dart';

import '../data/app_database.dart';
import '../data/app_settings_store.dart';
import '../data/cloud_config.dart';
import '../data/cloud_endpoint.dart';
import '../data/cloud_runtime.dart';
import '../data/cloud_sync.dart';
import '../data/device_label.dart';
import '../data/settings_auto_sync.dart';
import '../data/source_store.dart';
import '../theme.dart';
import '../widgets/focusable_card.dart';
import '../widgets/pairing_qr.dart';
import 'connect_device_screen.dart';

/// Pairs this device with a web-panel account and pulls its source list down.
/// No login happens here: the device shows a short code, the user enters it in
/// the panel (on a real keyboard), and this screen polls until it's claimed.
class CloudSyncScreen extends StatefulWidget {
  final SourceStore store;
  final AppDatabase db;

  /// Inject a fake in tests; defaults to the live Supabase-backed [CloudSync].
  final CloudSync? sync;

  const CloudSyncScreen({
    super.key,
    required this.store,
    required this.db,
    this.sync,
  });

  @override
  State<CloudSyncScreen> createState() => _CloudSyncScreenState();
}

class _CloudSyncScreenState extends State<CloudSyncScreen> {
  /// Rebuilt after a first-time server save: until then nothing cloud-facing
  /// exists to talk to. `late` (not `late final`) so the screen can create it
  /// once the server has been chosen without leaving the route.
  late CloudSync _sync = widget.sync ?? CloudSync(db: widget.db);

  bool _loading = true;
  bool _paired = false;
  bool _busy = false;
  String? _error;
  String? _status;
  PairingCode? _code;
  Timer? _poll;
  List<CloudProfile> _profiles = const [];
  String? _activeProfileId;
  DateTime? _knownRemoteRevision;
  CloudCryptoStatus _crypto = CloudCryptoStatus.off;

  /// The "connect a server" form is shown when this device has no endpoint
  /// (or the user chose Change). Option D: the server is a per-device setting,
  /// so an unconfigured build is expected, not broken.
  bool _serverSetup = false;
  bool _checkingServer = false;
  bool _serverBusy = false;
  String? _serverError;
  bool _manualServer = false;

  /// A server change was saved while a Supabase client already exists in this
  /// process. Nothing else may talk to either server until the app restarts.
  bool _restartPending = false;

  /// The well-known answer for the URL in [_serverUrl], ready to save.
  CloudEndpoint? _checkedEndpoint;

  final _serverUrl = TextEditingController();
  final _serverKey = TextEditingController();
  final _serverPanel = TextEditingController();

  /// The server reports this profile as unencrypted (or at an older key) after
  /// this device has already seen it encrypted. Always accompanies
  /// [CloudCryptoStatus.locked] — see [_refreshCrypto].
  bool _downgraded = false;

  /// The name this device suggests for itself while pairing, shown read-only so
  /// the user knows what will appear in the panel. Empty on an unknown platform
  /// (or if detection fails), in which case the hint is omitted entirely.
  String _suggestedLabel = '';

  @override
  void initState() {
    super.initState();
    _serverSetup = !CloudRuntime.hasServer;
    _loading = !_serverSetup;
    _clientStarted = CloudRuntime.hasServer;
    final endpoint = CloudRuntime.endpoint;
    if (endpoint != null) {
      _serverUrl.text = endpoint.url;
      _serverPanel.text = endpoint.panelUrl;
    }
    _init();
    detectSuggestedDeviceLabel().then((label) {
      if (mounted) setState(() => _suggestedLabel = label);
    });
  }

  @override
  void dispose() {
    _poll?.cancel();
    _serverUrl.dispose();
    _serverKey.dispose();
    _serverPanel.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (!CloudRuntime.hasServer) {
      if (mounted && _loading) {
        setState(() {
          _loading = false;
          _serverSetup = true;
        });
      }
      return;
    }
    try {
      await _sync.ensureAnonSession();
      if (await _sync.isPaired()) {
        if (mounted) setState(() => _paired = true);
        await _loadProfiles();
      } else {
        await _newCode();
      }
      // A paired device may have a settings backup from before a reinstall;
      // an unpaired one simply has no owner yet and the RPC is a no-op.
      unawaited(SettingsAutoSync.reconcile());
    } catch (e) {
      if (mounted) setState(() => _error = friendlyCloudError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Load the account's profiles and the device's active one, defaulting to the
  /// first profile when the device hasn't picked one yet.
  Future<void> _loadProfiles() async {
    final profiles = await _sync.listProfiles();
    var active = await _sync.activeProfileId();
    if (active == null && profiles.isNotEmpty) {
      active = profiles.first.id;
      try {
        await _sync.setProfile(active);
      } catch (_) {
        // Best-effort; the user can pick explicitly below.
      }
    }
    if (!mounted) return;
    setState(() {
      _profiles = profiles;
      _activeProfileId = active;
      _knownRemoteRevision = profiles
          .where((p) => p.id == active)
          .firstOrNull
          ?.updatedAt;
    });
    await _refreshCrypto();
  }

  /// Refresh the E2EE status for the active profile (best-effort; degrades to
  /// [CloudCryptoStatus.off] against a pre-migration backend or on error).
  ///
  /// A *downgrade* also resolves to [CloudCryptoStatus.locked], so it is carried
  /// separately: the two states need different words and different actions —
  /// "unlock this device in the panel" versus "the encryption this profile had
  /// has disappeared". Without [_downgraded] the distinct message never reaches
  /// the screen.
  Future<void> _refreshCrypto() async {
    final profileId = _activeProfileId;
    if (profileId == null) return;
    try {
      final state = await _sync.cryptoState(profileId);
      if (mounted) {
        setState(() {
          _crypto = state.status;
          _downgraded = state.downgraded;
        });
      }
    } catch (_) {
      // Leave the prior status; the pull/push paths surface real failures.
    }
  }

  /// Accept that a profile's encryption was turned off deliberately, clearing
  /// this device's sticky mark. Confirm-gated because the *legitimate* case (a
  /// panel-side disable) and the attack (a backend lying about E2EE state) look
  /// identical from here — only the user knows which happened, so the device
  /// asks rather than guessing.
  Future<void> _acknowledgeDowngrade() async {
    final profileId = _activeProfileId;
    if (profileId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Encryption turned off?'),
        content: const Text(
          'Only continue if you turned end-to-end encryption off yourself in '
          'the panel. If you did not, this device will start sending '
          'credentials the server can read.',
        ),
        actions: [
          TextButton(
            // See the note in sources_screen: a D-pad dialog with nothing
            // focused eats the first OK press.
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('I turned it off'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _sync.acknowledgeE2eeDowngrade(profileId);
    await _refreshCrypto();
  }

  Future<void> _switchProfile(String id) async {
    if (id == _activeProfileId || _busy) return;
    setState(() => _busy = true);
    try {
      await _sync.setProfile(id);
      if (!mounted) return;
      setState(() {
        _activeProfileId = id;
        _busy = false;
      });
      await _refreshCrypto();
      await _pull();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = friendlyCloudError(e);
          _busy = false;
        });
      }
    }
  }

  Future<void> _newCode() async {
    _poll?.cancel();
    final code = await _sync.requestPairingCode();
    if (!mounted) return;
    setState(() {
      _code = code;
      _error = null;
    });
    _poll = Timer.periodic(const Duration(seconds: 3), (_) => _checkClaim());
  }

  Future<void> _checkClaim() async {
    final code = _code;
    if (code == null) return;
    // Codes are short-lived; refresh once expired so the screen stays usable.
    if (DateTime.now().isAfter(code.expiresAt)) {
      try {
        await _newCode();
      } catch (_) {
        /* keep polling on the old code's failure */
      }
      return;
    }
    try {
      if (await _sync.pairingStatus(code.code)) {
        _poll?.cancel();
        if (!mounted) return;
        setState(() => _paired = true);
        await _loadProfiles();
        await _pull(initial: true);
        unawaited(SettingsAutoSync.reconcile());
      }
    } catch (_) {
      // Transient network error — the next tick retries.
    }
  }

  Future<void> _pull({bool initial = false}) async {
    final profileId = _activeProfileId;
    if (profileId == null) {
      setState(() => _error = 'No profile to sync — create one in the panel.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final count = await _sync.pullSources(widget.store, profileId);
      final metadata = await _sync.pullMetadata(widget.store, profileId);
      await _sync.pullFavorites(widget.store, profileId);
      await _sync.pullWatchState(widget.store, profileId);
      _knownRemoteRevision = (await _sync.profileRevision(
        profileId,
      ))?.updatedAt;
      if (!mounted) return;
      final sources = 'Synced $count source${count == 1 ? '' : 's'}';
      setState(
        () => _status =
            '${initial ? 'Paired — ' : ''}$sources'
            '${metadata ? ' · metadata updated' : ''}.',
      );
      unawaited(SettingsAutoSync.reconcile());
    } catch (e) {
      if (mounted) setState(() => _error = friendlyCloudError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refreshCrypto();
    }
  }

  Future<void> _copyCode() async {
    final code = _code?.code;
    if (code == null) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Code copied'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _openPanel() async {
    final panelUrl = CloudRuntime.panelUrl;
    if (panelUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No panel address configured for this server.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    final uri = Uri.tryParse(panelUrl);
    var ok = false;
    if (uri != null) {
      try {
        ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Couldn\'t open the link — visit it manually'),
        ),
      );
    }
  }

  Future<void> _push() async {
    final profileId = _activeProfileId;
    if (profileId == null) {
      setState(() => _error = 'No profile selected.');
      return;
    }
    CloudRevision? current;
    try {
      current = await _sync.profileRevision(profileId);
    } catch (error) {
      // A revision read failure must not silently permit an overwrite. Treat
      // the revision as unknown; the conservative confirmation below remains.
      if (mounted) {
        setState(() => _error = friendlyCloudError(error));
      }
    }
    if (!mounted) return;
    if (shouldWarnBeforeOverwrite(
      knownRemoteRevision: _knownRemoteRevision,
      currentRemoteRevision: current?.updatedAt,
      hasLocalChanges: true,
    )) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Panel changed'),
          content: const Text(
            'This profile changed on the panel since this device last '
            'synced. Pushing will replace those newer changes.',
          ),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Replace panel profile'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (proceed != true) return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Push to panel?'),
        content: Text(
          'This replaces the source list, metadata settings, and favorites of '
          'the selected profile ($_activeProfileName) with the ones on this '
          'device. Anything in that profile that isn\'t on this device will be '
          'removed.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Push'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final count = await _sync.pushSources(widget.store, profileId);
      await _sync.pushMetadata(widget.store, profileId);
      await _sync.pushFavorites(widget.store, profileId);
      // Watch state goes up as a delta, never as a whole-set replace: progress
      // belongs to the device that watched it, and a manual push must not erase
      // what another device has watched since. Everything queued is sent.
      await _sync.pushWatchDelta(widget.store, profileId);
      _knownRemoteRevision = (await _sync.profileRevision(
        profileId,
      ))?.updatedAt;
      if (!mounted) return;
      setState(
        () => _status =
            'Pushed $count source${count == 1 ? '' : 's'} · metadata · favorites '
            '· progress to $_activeProfileName.',
      );
      unawaited(SettingsAutoSync.pushNow());
    } catch (e) {
      if (mounted) setState(() => _error = friendlyCloudError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String get _activeProfileName {
    for (final p in _profiles) {
      if (p.id == _activeProfileId) return p.name.isEmpty ? 'profile' : p.name;
    }
    return 'the profile';
  }

  Future<void> _unpair() async {
    setState(() => _busy = true);
    try {
      await _sync.unpair(widget.store);
      if (!mounted) return;
      setState(() {
        _paired = false;
        _status = null;
      });
      await _newCode();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyCloudError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Cloud server (option D). The endpoint is per-device state; the screen is
  // the only place that writes it. See cloud/runtime-server.md.
  // ---------------------------------------------------------------------------

  bool _clientStarted = false;

  void _openServerSetup() {
    final endpoint = CloudRuntime.endpoint;
    if (endpoint != null) {
      _serverUrl.text = endpoint.url;
      _serverPanel.text = endpoint.panelUrl;
    }
    setState(() {
      _serverSetup = true;
      _serverError = null;
      _checkedEndpoint = null;
      _manualServer = false;
      _serverKey.clear();
    });
  }

  /// Fetches `/.well-known/iptvs-cloud.json` from the entered domain.
  ///
  /// Redirects are refused on purpose: the user typed one host, and a server
  /// that forwards the config to a different one is not what they asked for.
  Future<void> _checkServer() async {
    final base = normalizeCloudDiscoveryUrl(_serverUrl.text);
    if (base == null) {
      setState(() => _serverError = 'Enter an https:// address.');
      return;
    }
    setState(() {
      _checkingServer = true;
      _serverError = null;
      _checkedEndpoint = null;
    });
    final client = http.Client();
    try {
      final request = http.Request('GET', Uri.parse('$base$kCloudWellKnownPath'))
        ..followRedirects = false
        ..headers['accept'] = 'application/json';
      final streamed = await client
          .send(request)
          .timeout(const Duration(seconds: 6));
      if (streamed.statusCode != 200) {
        throw FormatException('HTTP ${streamed.statusCode}');
      }
      final length = streamed.contentLength;
      if (length != null && length > 64 * 1024) {
        throw const FormatException('configuration too large');
      }
      final body = await streamed.stream
          .bytesToString()
          .timeout(const Duration(seconds: 6));
      final endpoint = parseCloudWellKnown(body, baseUrl: base);
      if (endpoint == null) throw const FormatException('bad configuration');
      if (mounted) setState(() => _checkedEndpoint = endpoint);
    } catch (_) {
      if (mounted) {
        setState(
          () => _serverError =
              'No IPTVS cloud configuration at that address. '
              'You can enter the URL and key manually.',
        );
      }
    } finally {
      client.close();
      if (mounted) setState(() => _checkingServer = false);
    }
  }

  Future<void> _saveServer() async {
    final panelText = _serverPanel.text.trim();
    if (_manualServer && panelText.isEmpty) {
      setState(
        () => _serverError =
            'Enter the panel address — the page where the pairing code is '
            'entered.',
      );
      return;
    }
    final endpoint = _manualServer
        ? CloudEndpoint.parse(
            url: _serverUrl.text,
            anonKey: _serverKey.text,
            panelUrl: panelText,
          )
        : _checkedEndpoint;
    if (endpoint == null) {
      setState(
        () => _serverError = _manualServer
            ? 'Check the address and the publishable key.'
            : 'Read the server configuration first, or enter it manually.',
      );
      return;
    }
    final previous = CloudRuntime.endpoint;
    final switching = previous != null && !previous.sameServerAs(endpoint);
    setState(() {
      _serverBusy = true;
      _serverError = null;
    });
    try {
      if (switching) {
        // Different server: the old session and cloud caches mean nothing on
        // the new one and would only confuse the next boot.
        await CloudRuntime.forget();
      }
      await const AppSettingsStore().setCloudEndpoint(endpoint);
      if (!_clientStarted) {
        // Nothing was initialized at boot, so this process can start the client
        // now and the pairing UI appears without leaving the screen.
        await CloudRuntime.initialize(endpoint);
        _clientStarted = true;
        _sync = widget.sync ?? CloudSync(db: widget.db);
        if (!mounted) return;
        setState(() {
          _serverSetup = false;
          _serverBusy = false;
          _loading = true;
        });
        await _init();
        return;
      }
      if (!mounted) return;
      setState(() {
        _serverSetup = false;
        _serverBusy = false;
        _restartPending = true;
      });
      // The process already owns a Supabase client (and possibly a session for
      // the previous server): only a restart can apply the saved endpoint.
      await _promptRestart();
    } catch (e) {
      if (mounted) {
        setState(
          () => _serverError = 'Could not save the server: ${friendlyCloudError(e)}',
        );
      }
    } finally {
      if (mounted && _serverBusy) setState(() => _serverBusy = false);
    }
  }

  Future<void> _forgetServer() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget this server?'),
        content: const Text(
          'This device will be unpaired and its cloud caches removed. '
          'Sources, favorites and progress stored on this device stay.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _serverBusy = true);
    try {
      await CloudRuntime.forget();
      if (!mounted) return;
      _poll?.cancel();
      setState(() {
        _serverBusy = false;
        _serverSetup = true;
        _checkedEndpoint = null;
        _manualServer = false;
        _serverError = null;
        _status = null;
        _error = null;
        _paired = false;
        _code = null;
        _profiles = const [];
        _activeProfileId = null;
      });
      _serverUrl.clear();
      _serverKey.clear();
      _serverPanel.clear();
      if (_clientStarted) {
        setState(() => _restartPending = true);
        await _promptRestart();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _serverError = friendlyCloudError(e));
      }
    } finally {
      if (mounted && _serverBusy) setState(() => _serverBusy = false);
    }
  }

  Future<void> _promptRestart() async {
    final restart = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restart required'),
        content: const Text(
          'The cloud server was saved. Close IPTVS and open it again to use it.',
        ),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(Platform.isWindows ? 'Restart now' : 'Close app'),
          ),
        ],
      ),
    );
    if (restart == true) await _restartNow();
  }

  Future<void> _restartNow() async {
    if (Platform.isWindows) {
      try {
        await Process.start(Platform.resolvedExecutable, const []);
      } catch (_) {
        // Fall through to exit: the user can start it from the shortcut.
      }
    }
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cloud sync')),
      // Edge-to-edge (targetSdk 35+): keep the pairing/push controls clear of the
      // system bar.
      body: SafeArea(
        top: false,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            // Capped and centred: this screen is mostly running prose and a
            // pairing code, and unconstrained it ran edge to edge on a
            // maximised desktop window.
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: kSettingsMaxContentWidth,
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_restartPending)
                          ..._restartPendingBody()
                        else if (_serverSetup)
                          ..._serverSetupBody()
                        else ...[
                          _serverRow(),
                          const Divider(height: 32),
                          if (_paired) ..._pairedBody() else ..._pairingBody(),
                        ],
                        if (_status != null) ...[
                          const SizedBox(height: 20),
                          Text(
                            _status!,
                            style: const TextStyle(color: AppColors.accent),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 20),
                          Text(
                            _error!,
                            style: const TextStyle(color: AppColors.danger),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  /// The configured server, with the two actions that can change it.
  Widget _serverRow() {
    final endpoint = CloudRuntime.endpoint;
    if (endpoint == null) return const SizedBox.shrink();
    return Row(
      children: [
        const Icon(Icons.dns_outlined, size: 18, color: AppColors.textLo),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Server: ${endpoint.host}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppColors.textLo, fontSize: 13),
          ),
        ),
        TextButton(
          onPressed: _serverBusy ? null : _openServerSetup,
          child: const Text('Change'),
        ),
        TextButton(
          onPressed: _serverBusy ? null : _forgetServer,
          child: const Text('Forget'),
        ),
      ],
    );
  }

  List<Widget> _restartPendingBody() => [
    const Text(
      'Restart to apply the server',
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    const Text(
      'The server setting was saved. Close IPTVS and open it again; until '
      'then the cloud screen stays off rather than talking to the previous '
      'server with the new setting.',
      style: TextStyle(color: AppColors.textLo),
    ),
    const SizedBox(height: 20),
    FilledButton.icon(
      onPressed: _restartNow,
      icon: const Icon(Icons.restart_alt),
      label: Text(Platform.isWindows ? 'Restart now' : 'Close app'),
    ),
  ];

  List<Widget> _serverSetupBody() {
    final current = CloudRuntime.endpoint;
    return [
      const Text(
        'Connect a cloud server',
        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      const Text(
        'Cloud sync needs a server: your own IPTVS cloud or a shared one. '
        'Enter its address; if it publishes its configuration, the key is '
        'read automatically.',
        style: TextStyle(color: AppColors.textLo),
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _serverUrl,
        autocorrect: false,
        keyboardType: TextInputType.url,
        textInputAction: TextInputAction.next,
        decoration: const InputDecoration(
          labelText: 'Server address',
          hintText: 'https://cloud.example.com',
        ),
        onChanged: (_) {
          if (_checkedEndpoint != null) {
            setState(() => _checkedEndpoint = null);
          }
        },
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          FilledButton(
            onPressed: _checkingServer ? null : _checkServer,
            child: _checkingServer
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Check server'),
          ),
          if (_checkedEndpoint case final endpoint?) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Found: ${endpoint.host}',
                style: const TextStyle(color: AppColors.accent, fontSize: 13),
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 12),
      TextButton(
        onPressed: () => setState(() {
          _manualServer = !_manualServer;
        }),
        child: Text(
          _manualServer
              ? 'Hide manual entry'
              : 'Enter the URL and key manually',
        ),
      ),
      if (_manualServer) ...[
        const SizedBox(height: 4),
        TextField(
          controller: _serverKey,
          autocorrect: false,
          enableSuggestions: false,
          decoration: const InputDecoration(
            labelText: 'Publishable (anon) key',
            helperText: 'Public by design. Never the service_role key.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _serverPanel,
          autocorrect: false,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: 'Panel address',
            helperText: 'Where the pairing code is entered.',
          ),
        ),
      ],
      if (current != null) ...[
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _serverBusy
                ? null
                : () => setState(() {
                    _serverSetup = false;
                    _serverError = null;
                  }),
            child: const Text('Cancel'),
          ),
        ),
      ],
      if (_serverError != null) ...[
        const SizedBox(height: 8),
        Text(
          _serverError!,
          style: const TextStyle(color: AppColors.danger),
        ),
      ],
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _serverBusy ? null : _saveServer,
        icon: _serverBusy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.cloud_outlined),
        label: const Text('Save server'),
      ),
    ];
  }

  List<Widget> _pairingBody() => [
    const Text(
      'Pair this device',
      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
    ),
    const SizedBox(height: 8),
    Text(
      'Open the panel on your phone or computer, sign in, and enter this '
      'code under Devices:',
      style: const TextStyle(color: AppColors.textLo),
    ),
    const SizedBox(height: 20),
    Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: InkWell(
          onTap: _code == null ? null : _copyCode,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
            decoration: BoxDecoration(
              color: AppColors.panelHi,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                // Balances the trailing copy icon so the code stays centered.
                const SizedBox(width: 38),
                // Scale the code down so any glyph mix fits the box on a
                // narrow phone instead of overflowing.
                Expanded(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Text(
                      _code?.code ?? '········',
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 40,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 8,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                const Icon(Icons.copy_rounded, color: AppColors.textLo),
              ],
            ),
          ),
        ),
      ),
    ),
    const SizedBox(height: 8),
    const Center(
      child: Text(
        'Tap the code to copy it',
        style: TextStyle(color: AppColors.textLo, fontSize: 12),
      ),
    ),
    if (_code case final code?) ...[
      if (CloudRuntime.panelUrl.isNotEmpty) ...[
        const SizedBox(height: 20),
        Center(
          child: PairingQrView(
            link: pairingPanelLink(CloudRuntime.panelUrl, code.code),
          ),
        ),
      ],
    ],
    // Read-only on purpose: naming happens in the panel, on a real keyboard.
    // Adding a text field here would put a focus target — and a Back-ladder
    // rung — on a screen reached by D-pad remote.
    if (_suggestedLabel.isNotEmpty) ...[
      const SizedBox(height: 12),
      Center(
        child: Text(
          'This device will appear as "$_suggestedLabel". '
          'You can give it another name in the panel.',
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppColors.textLo, fontSize: 12),
        ),
      ),
    ],
    const SizedBox(height: 16),
    if (CloudRuntime.panelUrl.isNotEmpty)
      Center(
        child: InkWell(
          onTap: _openPanel,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.open_in_new, size: 16, color: AppColors.accent),
                const SizedBox(width: 6),
                Text(
                  CloudRuntime.panelUrl,
                  style: const TextStyle(
                    color: AppColors.accent,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    const SizedBox(height: 24),
    FilledButton.icon(
      onPressed: _busy ? null : _newCode,
      icon: const Icon(Icons.refresh),
      label: const Text('New code'),
    ),
    const SizedBox(height: 8),
    TextButton.icon(
      onPressed: _serverBusy ? null : _openServerSetup,
      icon: const Icon(Icons.dns_outlined, size: 16),
      label: const Text('Use a different server'),
    ),
  ];

  List<Widget> _pairedBody() => [
    Row(
      children: const [
        Icon(Icons.cloud_done_outlined, color: AppColors.accent),
        SizedBox(width: 10),
        Text(
          'This device is paired',
          style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
        ),
      ],
    ),
    const SizedBox(height: 8),
    const Text(
      'Sync this device with a profile in the panel. Pull replaces the '
      'cloud-managed sources, metadata, and favorites here with the '
      'profile\'s (sources you added locally are kept). Push sends this '
      'device\'s set up, replacing the profile\'s. Newest change wins.',
      style: TextStyle(color: AppColors.textLo),
    ),
    ..._profileSection(),
    const SizedBox(height: 20),
    _cryptoStatusLine(),
    const SizedBox(height: 20),
    FilledButton.icon(
      onPressed: _busy ? null : () => _pull(),
      icon: _busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
      label: const Text('Pull now'),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      // Push is disabled on a locked E2EE device — it holds no content key, so
      // it can't produce the encrypted secret the server would accept.
      onPressed: (_busy || _crypto == CloudCryptoStatus.locked) ? null : _push,
      icon: const Icon(Icons.cloud_upload_outlined),
      label: const Text('Push to panel'),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _busy ? null : _authoriseAnotherDevice,
      icon: const Icon(Icons.qr_code_scanner),
      label: const Text('Authorise another device'),
    ),
    const SizedBox(height: 12),
    OutlinedButton.icon(
      onPressed: _busy ? null : _unpair,
      icon: const Icon(Icons.link_off),
      label: const Text('Unpair this device'),
    ),
  ];

  /// Hands this device's account authority to a second device (a TV) by
  /// claiming its pairing code — see [ConnectDeviceScreen] and
  /// `claim_pairing_as_device`. Nothing leaves this screen's account: the
  /// server resolves the account from this device's own `devices` row.
  Future<void> _authoriseAnotherDevice() async {
    final connected = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => ConnectDeviceScreen(sync: _sync),
      ),
    );
    if (!mounted || connected != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Device authorised — it will finish pairing on its own.'),
      ),
    );
  }

  /// A status line describing the profile's end-to-end-encryption state. Locked
  /// devices get the actionable unlock message (and Push is disabled above).
  Widget _cryptoStatusLine() {
    // Checked before the switch: a downgrade *is* `locked`, but the locked text
    // ("unlock this device in the panel") is actively misleading here — there is
    // nothing to unlock, because the server is claiming the encryption is gone.
    if (_downgraded) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.gpp_maybe_outlined,
            size: 18,
            color: AppColors.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  kCloudE2eeDowngradedMessage,
                  style: TextStyle(color: AppColors.danger, fontSize: 13),
                ),
                const SizedBox(height: 4),
                TextButton(
                  onPressed: _busy ? null : _acknowledgeDowngrade,
                  child: const Text('I turned encryption off on purpose'),
                ),
              ],
            ),
          ),
        ],
      );
    }
    final (IconData icon, String text, Color color) = switch (_crypto) {
      CloudCryptoStatus.off => (
        Icons.lock_open_outlined,
        'End-to-end encryption: off (secrets protected by the server\'s access '
            'control and TLS).',
        AppColors.textLo,
      ),
      CloudCryptoStatus.ready => (
        Icons.lock_outline,
        'End-to-end encryption: on — this device is set up and can sync '
            'credentials.',
        AppColors.accent,
      ),
      CloudCryptoStatus.locked => (
        Icons.lock,
        'This profile is end-to-end encrypted. Open the panel and unlock it to '
            'finish setting up this device. Until then, Push is disabled and '
            'sources without saved credentials need attention.',
        AppColors.danger,
      ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: TextStyle(color: color, fontSize: 13)),
        ),
      ],
    );
  }

  /// The profile picker: lists the account's profiles, highlights the active
  /// one, and switches (then re-pulls) on selection. Profiles are created and
  /// renamed in the web panel.
  List<Widget> _profileSection() {
    if (_profiles.isEmpty) {
      return const [
        SizedBox(height: 20),
        Text(
          'No profiles yet — create one in the panel, then pull.',
          style: TextStyle(color: AppColors.textLo),
        ),
      ];
    }
    return [
      const SizedBox(height: 20),
      const Text('Profile', style: TextStyle(fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text(
        'Pick which profile this device syncs.',
        style: TextStyle(color: AppColors.textLo, fontSize: 12),
      ),
      const SizedBox(height: 10),
      for (var i = 0; i < _profiles.length; i++)
        _ProfileRow(
          name: _profiles[i].name.isEmpty ? 'Profile' : _profiles[i].name,
          selected: _profiles[i].id == _activeProfileId,
          autofocus: _profiles[i].id == _activeProfileId,
          onTap: _busy ? null : () => _switchProfile(_profiles[i].id),
        ),
    ];
  }
}

class _ProfileRow extends StatelessWidget {
  final String name;
  final bool selected;
  final bool autofocus;
  final VoidCallback? onTap;

  const _ProfileRow({
    required this.name,
    required this.selected,
    required this.autofocus,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FocusableCard(
      autofocus: autofocus,
      onTap: onTap ?? () {},
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? AppColors.accent : AppColors.textLo,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? AppColors.textHi : AppColors.textLo,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
