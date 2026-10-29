import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/image_compress.dart';
import '../core/settings.dart';
import '../core/speech.dart';
import '../sync/background_sync.dart';
import '../sync/sync_service.dart';
import '../sync/update_service.dart';
import 'format.dart';
import 'update_dialog.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _repo;
  late final TextEditingController _branch;
  late final TextEditingController _token;
  late final TextEditingController _pass;
  bool _showToken = false;
  bool _showPass = false;
  bool _busy = false;
  bool _checking = false;
  String? _result;
  bool _resultOk = false;

  @override
  void initState() {
    super.initState();
    final c = context.read<AppSettings>().config;
    _repo = TextEditingController(text: c.repo);
    _branch = TextEditingController(text: c.branch);
    _token = TextEditingController(text: c.token);
    _pass = TextEditingController(text: c.passphrase);
  }

  @override
  void dispose() {
    _repo.dispose();
    _branch.dispose();
    _token.dispose();
    _pass.dispose();
    super.dispose();
  }

  SyncConfig _cfg() => SyncConfig(
        token: _token.text.trim(),
        repo: _repo.text.trim(),
        branch: _branch.text.trim().isEmpty ? 'main' : _branch.text.trim(),
        passphrase: _pass.text,
      );

  Future<void> _connect() async {
    final cfg = _cfg();
    if (!cfg.isComplete) {
      setState(() {
        _resultOk = false;
        _result =
            'Fill in the repository (owner/name), branch, token and passphrase.';
      });
      return;
    }
    final sync = context.read<SyncService>();
    final settings = context.read<AppSettings>();
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final msg = await sync.verify(cfg);
      await settings.saveSync(cfg);
      if (!mounted) return;
      setState(() {
        _resultOk = true;
        _result = msg;
      });
      sync.maybeAutoSync();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _resultOk = false;
        _result = '$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect sync?'),
        content: const Text(
            'Your notes stay on this device. The token and passphrase are removed from it.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Disconnect')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await context.read<AppSettings>().clearSync();
    if (!mounted) return;
    setState(() {
      _token.clear();
      _pass.clear();
      _result = null;
    });
  }

  Future<void> _checkUpdates() async {
    final svc = context.read<UpdateService>();
    final messenger = ScaffoldMessenger.of(context);
    if (!svc.supported) {
      messenger.showSnackBar(const SnackBar(
          content: Text('Update checks are available in release builds.')));
      return;
    }
    setState(() => _checking = true);
    try {
      final info = await svc.check();
      if (!mounted) return;
      if (info == null) {
        messenger.showSnackBar(
            const SnackBar(content: Text('You are on the latest version.')));
      } else {
        await showUpdateDialog(context, info);
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not check: $e')));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _section(context, 'GitHub sync', [
                Text(
                  'Notes and attachments are encrypted on this device with your passphrase, '
                  'then stored in a private GitHub repository you own.',
                  style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _repo,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Repository',
                    hintText: 'your-name/inkwell-sync',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _branch,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Branch'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _token,
                  obscureText: !_showToken,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Fine-grained access token',
                    suffixIcon: IconButton(
                      icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _showToken = !_showToken),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pass,
                  obscureText: !_showPass,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'Backup passphrase',
                    helperText:
                        'Use the same passphrase on every device. If you lose it, synced notes cannot be recovered.',
                    helperMaxLines: 3,
                    suffixIcon: IconButton(
                      icon: Icon(_showPass ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _showPass = !_showPass),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _busy ? null : _connect,
                      icon: _busy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.link),
                      label: const Text('Save & connect'),
                    ),
                    Consumer<SyncService>(
                      builder: (context, sync, _) => OutlinedButton.icon(
                        onPressed:
                            (!sync.configured || sync.running) ? null : sync.syncNow,
                        icon: const Icon(Icons.sync),
                        label: Text(sync.running ? 'Syncing…' : 'Sync now'),
                      ),
                    ),
                    if (settings.config.isComplete)
                      TextButton(
                        onPressed: _disconnect,
                        child: const Text('Disconnect'),
                      ),
                  ],
                ),
                if (_result != null) ...[
                  const SizedBox(height: 12),
                  _Banner(text: _result!, ok: _resultOk),
                ],
                const SizedBox(height: 8),
                Consumer<SyncService>(
                  builder: (context, sync, _) {
                    final when = sync.lastSyncAt;
                    final line = sync.lastError ??
                        (when == null
                            ? 'Not synced yet.'
                            : 'Last sync ${fmtWhen(when.toUtc())} · ${sync.lastMessage ?? 'done'}');
                    return Text(line,
                        style: text.bodySmall?.copyWith(
                            color: sync.lastError != null ? cs.error : cs.onSurfaceVariant));
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sync automatically'),
                  subtitle: const Text(
                      'After changes, when the app opens, and every few minutes.'),
                  value: settings.autoSync,
                  onChanged: settings.setAutoSync,
                ),
                if (BackgroundSync.supported)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sync in the background'),
                    subtitle: const Text(
                        'Roughly every 30 minutes while the app is closed, on a '
                        'network connection and not on low battery. Android '
                        'decides the exact timing.'),
                    value: settings.backgroundSync,
                    onChanged: settings.autoSync ? settings.setBackgroundSync : null,
                  ),
              ]),
              _section(context, 'Photos', [
                SegmentedButton<ImageCompression>(
                  showSelectedIcon: false,
                  segments: [
                    for (final c in ImageCompression.values)
                      ButtonSegment(value: c, label: Text(c.label)),
                  ],
                  selected: {settings.imageCompression},
                  onSelectionChanged: (s) => settings.setImageCompression(s.first),
                ),
                const SizedBox(height: 8),
                Text(settings.imageCompression.description,
                    style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
              ]),
              _section(context, 'Voice and quick add', [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Prefer on-device recognition'),
                  subtitle: const Text(
                      'Asks your phone or PC to transcribe without the internet. '
                      'It only works if the offline speech pack for your language '
                      'is installed; otherwise your device may use its online '
                      'speech service. Inkwell itself never uploads audio.'),
                  value: settings.onDeviceSpeech,
                  onChanged: settings.setOnDeviceSpeech,
                ),
                Consumer<VoiceInput>(
                  builder: (context, voice, _) => DropdownButtonFormField<String>(
                    value: voice.locales.any((l) => l.localeId == settings.speechLocale)
                        ? settings.speechLocale
                        : '',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Speech language'),
                    items: [
                      const DropdownMenuItem(value: '', child: Text('Device language')),
                      for (final l in voice.locales)
                        DropdownMenuItem(
                          value: l.localeId,
                          child: Text(l.name, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onTap: voice.ensureReady,
                    onChanged: (v) => settings.setSpeechLocale(v ?? ''),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Dates read day first'),
                  subtitle: Text(settings.dayFirstDates
                      ? '“12/11” means 12 November.'
                      : '“12/11” means December 11.'),
                  value: settings.dayFirstDates,
                  onChanged: settings.setDayFirstDates,
                ),
                Text(
                  'Quick add understands English phrases such as “remind me to pay '
                  'rent on the 1st every month !1 #home”. It runs entirely on '
                  'this device with simple pattern matching, not an AI model, so '
                  'unusual wording may need a manual tweak.',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
              _section(context, 'Set up in two minutes', [
                Text(
                  '1. On GitHub create a new PRIVATE repository (tick "Add a README").\n'
                  '2. Settings → Developer settings → Personal access tokens → Fine-grained tokens → '
                  'Generate new token.\n'
                  '3. Repository access: only select the repository from step 1.\n'
                  '4. Permissions → Repository permissions → Contents: Read and write.\n'
                  '5. Paste the token above, choose a passphrase, tap Save & connect.\n'
                  '6. On your other devices, enter the same repository, token and passphrase.',
                  style: text.bodyMedium,
                ),
              ]),
              _section(context, 'Appearance', [
                SegmentedButton<ThemeMode>(
                  segments: const [
                    ButtonSegment(
                        value: ThemeMode.system,
                        label: Text('System'),
                        icon: Icon(Icons.brightness_auto)),
                    ButtonSegment(
                        value: ThemeMode.light,
                        label: Text('Light'),
                        icon: Icon(Icons.light_mode_outlined)),
                    ButtonSegment(
                        value: ThemeMode.dark,
                        label: Text('Dark'),
                        icon: Icon(Icons.dark_mode_outlined)),
                  ],
                  selected: {settings.themeMode},
                  onSelectionChanged: (s) => settings.setThemeMode(s.first),
                ),
              ]),
              _section(context, 'About', [
                FutureBuilder<String>(
                  future: context.read<UpdateService>().currentVersion(),
                  builder: (context, snap) =>
                      Text('Inkwell ${snap.data ?? ''}', style: text.titleSmall),
                ),
                const SizedBox(height: 4),
                Text(
                  'Updates come from this app\'s GitHub Releases page.',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _checking ? null : _checkUpdates,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.system_update_alt),
                    label: const Text('Check for updates'),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(BuildContext context, String title, List<Widget> children) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Card(
        elevation: 0,
        color: cs.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  style: Theme.of(context)
                      .textTheme
                      .titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 12),
              ...children,
            ],
          ),
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.ok});

  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ok ? cs.primaryContainer : cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.check_circle_outline : Icons.error_outline,
              size: 20,
              color: ok ? cs.onPrimaryContainer : cs.onErrorContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(
                    color: ok ? cs.onPrimaryContainer : cs.onErrorContainer)),
          ),
        ],
      ),
    );
  }
}
