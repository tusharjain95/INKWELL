import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:provider/provider.dart';

import '../core/image_compress.dart';
import '../core/reminders.dart';
import '../core/settings.dart';
import '../core/speech.dart';
import '../core/store.dart';
import '../sync/background_sync.dart';
import '../sync/drive_auth.dart';
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
  late final TextEditingController _drivePass;
  bool _showDrivePass = false;
  bool _driveBusy = false;
  bool _driveOk = false;
  bool _driveDialogOpen = false;
  bool _driveCancelled = false;
  String? _driveResult;
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
    _drivePass = TextEditingController(
        text: context.read<AppSettings>().drivePassphrase);
  }

  @override
  void dispose() {
    _repo.dispose();
    _branch.dispose();
    _token.dispose();
    _pass.dispose();
    _drivePass.dispose();
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

  Future<void> _switchProvider(SyncProvider p) async {
    final settings = context.read<AppSettings>();
    if (settings.syncProvider == p) return;
    final store = context.read<NoteStore>();
    await settings.setSyncProvider(p);
    // Everything on this device is uploaded to the new place; copies that are
    // already there are recognised and not duplicated.
    await store.resetSyncBaseline();
    if (mounted) {
      setState(() {
        _result = null;
        _driveResult = null;
      });
    }
  }

  Future<void> _driveSignIn() async {
    final pass = _drivePass.text;
    if (pass.isEmpty) {
      setState(() {
        _driveOk = false;
        _driveResult = 'Choose a backup passphrase first. Use the same one on every device.';
      });
      return;
    }
    final sync = context.read<SyncService>();
    final settings = context.read<AppSettings>();
    final store = context.read<NoteStore>();
    final nav = Navigator.of(context);
    final auth = DriveAuth();
    setState(() {
      _driveBusy = true;
      _driveResult = null;
      _driveCancelled = false;
    });
    try {
      final code = await auth.start();
      if (!mounted) return;
      _driveDialogOpen = true;
      unawaited(showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DeviceCodeDialog(
          code: code,
          onCancel: () {
            _driveCancelled = true;
            _driveDialogOpen = false;
            Navigator.of(context, rootNavigator: true).pop();
          },
        ),
      ));
      final tokens =
          await auth.waitForApproval(code, cancelled: () => _driveCancelled);
      if (_driveDialogOpen && mounted) {
        _driveDialogOpen = false;
        nav.pop();
      }
      final email = await auth.emailFor(tokens.accessToken) ?? '';
      final msg =
          await sync.verifyDrive(pass, refreshToken: tokens.refreshToken);
      await settings.saveDrive(
          refreshToken: tokens.refreshToken, email: email, passphrase: pass);
      await settings.setSyncProvider(SyncProvider.drive);
      await store.resetSyncBaseline();
      if (!mounted) return;
      setState(() {
        _driveOk = true;
        _driveResult = msg;
      });
      sync.maybeAutoSync();
    } catch (e) {
      if (_driveDialogOpen && mounted) {
        _driveDialogOpen = false;
        nav.pop();
      }
      if (!mounted) return;
      if (_driveCancelled) {
        setState(() => _driveResult = null);
      } else {
        setState(() {
          _driveOk = false;
          _driveResult = '$e';
        });
      }
    } finally {
      if (mounted) setState(() => _driveBusy = false);
    }
  }

  Future<void> _driveDisconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect Google Drive?'),
        content: const Text(
            'Your notes stay on this device and in Drive. The Google sign-in and passphrase are removed from this device.'),
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
    await context.read<AppSettings>().clearDrive();
    if (!mounted) return;
    setState(() {
      _drivePass.clear();
      _driveResult = null;
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
              _section(context, 'Sync to', [
                SegmentedButton<SyncProvider>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                        value: SyncProvider.github,
                        label: Text('GitHub'),
                        icon: Icon(Icons.code)),
                    ButtonSegment(
                        value: SyncProvider.drive,
                        label: Text('Google Drive'),
                        icon: Icon(Icons.add_to_drive_outlined)),
                  ],
                  selected: {settings.syncProvider},
                  onSelectionChanged: (v) => _switchProvider(v.first),
                ),
                const SizedBox(height: 8),
                Text(
                  'Both keep your notes end-to-end encrypted with your passphrase. '
                  'Switching uploads everything on this device to the new place.',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ]),
              if (settings.syncProvider == SyncProvider.github)
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
              ]),
              if (settings.syncProvider == SyncProvider.drive)
                _section(context, 'Google Drive sync', [
                  Text(
                    'Notes and attachments are encrypted on this device with your '
                    'passphrase, then saved in a folder called "Inkwell Sync" in '
                    'your Google Drive. Inkwell can only see files it created itself, '
                    'never your other Drive files, and Google only ever sees '
                    'encrypted data. Please do not edit or delete files in that folder.',
                    style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  const SizedBox(height: 16),
                  if (!DriveAuth.configured)
                    const _Banner(
                        ok: false,
                        text: 'This build has no Google credentials, so Drive sign-in '
                            'is unavailable. See "Google Drive sync" in the README.')
                  else ...[
                    if (settings.driveSignedIn)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.account_circle_outlined),
                        title: Text(settings.driveEmail.isEmpty
                            ? 'Signed in to Google'
                            : settings.driveEmail),
                        subtitle: const Text('Signed in'),
                      ),
                    TextField(
                      controller: _drivePass,
                      obscureText: !_showDrivePass,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'Backup passphrase',
                        helperText:
                            'Use the same passphrase on every device. If you lose it, synced notes cannot be recovered.',
                        helperMaxLines: 3,
                        suffixIcon: IconButton(
                          icon: Icon(_showDrivePass
                              ? Icons.visibility_off
                              : Icons.visibility),
                          onPressed: () =>
                              setState(() => _showDrivePass = !_showDrivePass),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: _driveBusy ? null : _driveSignIn,
                          icon: _driveBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2))
                              : const Icon(Icons.login),
                          label: Text(settings.driveSignedIn
                              ? 'Sign in again'
                              : 'Sign in with Google'),
                        ),
                        if (settings.driveSignedIn)
                          TextButton(
                            onPressed: _driveDisconnect,
                            child: const Text('Disconnect'),
                          ),
                      ],
                    ),
                    if (_driveResult != null) ...[
                      const SizedBox(height: 12),
                      _Banner(text: _driveResult!, ok: _driveOk),
                    ],
                  ],
                ]),
              _section(context, 'Sync', [
                Consumer<SyncService>(
                  builder: (context, sync, _) => Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed:
                          (!sync.configured || sync.running) ? null : sync.syncNow,
                      icon: const Icon(Icons.sync),
                      label: Text(sync.running ? 'Syncing…' : 'Sync now'),
                    ),
                  ),
                ),
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
              if (context.read<ReminderService>().supported)
                _section(context, 'Task reminders', [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Notify when a task is due'),
                    subtitle: Text(Platform.isAndroid
                        ? 'Uses your phone\'s alarm service, so it works with the '
                            'app closed. If reminders are late, allow "Alarms & '
                            'reminders" and set Inkwell\'s battery use to '
                            'unrestricted in Android settings.'
                        : 'Shown while Inkwell is running, including in the system '
                            'tray.'),
                    value: settings.remindersEnabled,
                    onChanged: (v) async {
                      final reminders = context.read<ReminderService>();
                      final messenger = ScaffoldMessenger.of(context);
                      await settings.setRemindersEnabled(v);
                      if (v && !await reminders.requestPermission()) {
                        messenger.showSnackBar(const SnackBar(
                            content: Text(
                                'Notifications are blocked. Allow them for Inkwell in system settings.')));
                      }
                    },
                  ),
                  DropdownButtonFormField<int>(
                    key: ValueKey('hour${settings.reminderHour}'),
                    initialValue: settings.reminderHour,
                    decoration: const InputDecoration(
                        labelText: 'Time for tasks that only have a date'),
                    items: [
                      for (final h in [6, 7, 8, 9, 10, 12, 14, 18])
                        DropdownMenuItem(
                            value: h,
                            child: Text('${h.toString().padLeft(2, '0')}:00')),
                    ],
                    onChanged: settings.remindersEnabled
                        ? (v) => settings.setReminderHour(v ?? 9)
                        : null,
                  ),
                ]),
              if (Platform.isWindows)
                _section(context, 'Windows', [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Keep running in the system tray'),
                    subtitle: const Text(
                        'Closing the window hides Inkwell instead of quitting, so '
                        'it keeps syncing and showing reminders. Use the tray icon '
                        'menu to quit.'),
                    value: settings.keepInTray,
                    onChanged: settings.setKeepInTray,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Start with Windows'),
                    subtitle: const Text('Starts minimised to the tray at sign-in.'),
                    value: settings.startWithWindows,
                    onChanged: settings.setStartWithWindows,
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
                    key: ValueKey('${settings.speechLocale}/${voice.locales.length}'),
                    initialValue: voice.locales.any((l) => l.localeId == settings.speechLocale)
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
              if (settings.syncProvider == SyncProvider.github)
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


/// Shows the code to type at google.com/device while sign-in is pending.
class _DeviceCodeDialog extends StatelessWidget {
  const _DeviceCodeDialog({required this.code, required this.onCancel});

  final DeviceCode code;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return AlertDialog(
      title: const Text('Sign in to Google'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('1. Open ${code.verificationUrl} on any device.'),
          const SizedBox(height: 8),
          const Text('2. Enter this code and approve access:'),
          const SizedBox(height: 12),
          Center(
            child: SelectableText(
              code.userCode,
              style: text.headlineMedium
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 2),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              FilledButton.tonalIcon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open'),
                onPressed: () => launchUrl(Uri.parse(code.verificationUrl),
                    mode: LaunchMode.externalApplication),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copy code'),
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: code.userCode)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Row(
            children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Expanded(child: Text('Waiting for approval…')),
            ],
          ),
        ],
      ),
      actions: [TextButton(onPressed: onCancel, child: const Text('Cancel'))],
    );
  }
}
