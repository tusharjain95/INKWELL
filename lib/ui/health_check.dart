import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/hub.dart';
import '../core/settings.dart';
import '../core/store.dart';
import '../core/telegram.dart';
import '../sync/sync_service.dart';

enum _Level { ok, warn, bad }

class _Row {
  const _Row(this.level, this.title, this.detail);
  final _Level level;
  final String title;
  final String detail;
}

/// One place that says what works and what does not.
class HealthCheck extends StatefulWidget {
  const HealthCheck({super.key});

  @override
  State<HealthCheck> createState() => _HealthCheckState();
}

class _HealthCheckState extends State<HealthCheck> {
  List<_Row>? _rows;
  bool _busy = false;

  Future<void> _run() async {
    final settings = context.read<AppSettings>();
    final sync = context.read<SyncService>();
    final store = context.read<NoteStore>();
    final hub = context.read<HubService>();
    setState(() => _busy = true);
    final rows = <_Row>[];

    rows.add(_Row(_Level.ok, 'Notes on this device',
        '${store.query().length} notes and tasks.'));

    // Sync
    if (!settings.syncReady) {
      rows.add(const _Row(_Level.warn, 'Sync',
          'Not set up. Notes stay on this device only.'));
    } else if (sync.lastError != null) {
      rows.add(_Row(_Level.bad, 'Sync', sync.lastError!));
    } else {
      final waiting = store.state.dirty.length;
      rows.add(_Row(
          waiting > 0 ? _Level.warn : _Level.ok,
          'Sync (${sync.providerLabel})',
          waiting > 0 ? '$waiting change(s) waiting to upload.' : 'Up to date.'));
    }

    // Telegram
    if (settings.telegramToken.isEmpty) {
      rows.add(const _Row(_Level.warn, 'Telegram', 'No bot token yet.'));
    } else {
      try {
        final name = await TelegramApi(settings.telegramToken).getMe();
        rows.add(_Row(_Level.ok, 'Telegram bot', '@$name responds.'));
      } on HubException catch (e) {
        rows.add(_Row(_Level.bad, 'Telegram bot', e.message));
      }
      rows.add(settings.telegramChat.isEmpty
          ? const _Row(_Level.warn, 'Telegram chat', 'Not connected. Use "Find my chat".')
          : const _Row(_Level.ok, 'Telegram chat', 'Connected.'));
      if (!settings.hubEnabled) {
        rows.add(const _Row(_Level.warn, 'Telegram hub',
            'Off on this device. Turn it on for one device only (usually your phone).'));
      } else if (hub.lastError != null) {
        rows.add(_Row(_Level.bad, 'Telegram hub', hub.lastError!));
      } else {
        rows.add(_Row(_Level.ok, 'Telegram hub', hub.lastMessage ?? 'Running.'));
      }
    }

    // Email relay
    if (settings.botConfigured) {
      try {
        final n = (await BotInbox(baseUrl: settings.botUrl, key: settings.botKey).fetch()).length;
        rows.add(_Row(_Level.ok, 'Email relay', 'Reachable. $n waiting.'));
      } on HubException catch (e) {
        rows.add(_Row(_Level.bad, 'Email relay', e.message));
      }
    } else {
      rows.add(const _Row(_Level.warn, 'Email relay', 'Not set up (optional).'));
    }

    if (!mounted) return;
    setState(() {
      _rows = rows;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Color color(_Level l) => switch (l) {
          _Level.ok => cs.primary,
          _Level.warn => cs.tertiary,
          _Level.bad => cs.error,
        };
    IconData icon(_Level l) => switch (l) {
          _Level.ok => Icons.check_circle,
          _Level.warn => Icons.info_outline,
          _Level.bad => Icons.error_outline,
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        FilledButton.tonalIcon(
          onPressed: _busy ? null : _run,
          icon: const Icon(Icons.health_and_safety_outlined),
          label: Text(_busy ? 'Checking…' : 'Run checks'),
        ),
        for (final r in _rows ?? const <_Row>[])
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: Icon(icon(r.level), color: color(r.level)),
            title: Text(r.title),
            subtitle: Text(r.detail),
          ),
      ],
    );
  }
}
