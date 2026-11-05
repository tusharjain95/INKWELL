import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/hub.dart';
import '../core/settings.dart';
import '../core/telegram.dart';
import 'format.dart';

List<DropdownMenuItem<int>> _hours() => [
      for (var h = 0; h < 24; h++)
        DropdownMenuItem(value: h, child: Text('${h.toString().padLeft(2, '0')}:00')),
    ];

const List<String> _days = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday',
];

class _Result extends StatelessWidget {
  const _Result({required this.text, required this.ok});
  final String text;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ok ? cs.primaryContainer : cs.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(text,
          style: TextStyle(color: ok ? cs.onPrimaryContainer : cs.onErrorContainer)),
    );
  }
}

/// Settings for the Telegram bot, email screening, digests and escalation.
class HubSettings extends StatefulWidget {
  const HubSettings({super.key});

  @override
  State<HubSettings> createState() => _HubSettingsState();
}

class _HubSettingsState extends State<HubSettings> {
  late final TextEditingController _url;
  late final TextEditingController _key;
  late final TextEditingController _token;
  late final TextEditingController _chat;
  bool _showKey = false;
  bool _showToken = false;
  bool _busy = false;
  bool _ok = false;
  String? _result;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppSettings>();
    _url = TextEditingController(text: s.botUrl);
    _key = TextEditingController(text: s.botKey);
    _token = TextEditingController(text: s.telegramToken);
    _chat = TextEditingController(text: s.telegramChat);
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    _token.dispose();
    _chat.dispose();
    super.dispose();
  }

  Future<void> _save() => context.read<AppSettings>().saveHub(
        url: _url.text,
        key: _key.text,
        token: _token.text,
        chat: _chat.text,
      );

  Future<void> _test() async {
    final hub = context.read<HubService>();
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      await _save();
      final msg = await hub.test();
      if (!mounted) return;
      setState(() {
        _ok = true;
        _result = msg;
      });
    } on HubException catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _result = 'Test failed: $e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final muted = text.bodySmall?.copyWith(color: cs.onSurfaceVariant);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Send tasks and notes to Inkwell from Telegram, turn important emails '
          'into tasks, and get a morning digest, an evening nudge, a weekly '
          'review and escalation of overdue high-priority tasks. See '
          'bot/README.md for the one-time setup (free).',
          style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _url,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Bot address',
            hintText: 'https://your-project.vercel.app',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _key,
          obscureText: !_showKey,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Inkwell key',
            helperText: 'The INKWELL_KEY value from Vercel.',
            suffixIcon: IconButton(
              icon: Icon(_showKey ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showKey = !_showKey),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _token,
          obscureText: !_showToken,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: 'Telegram bot token',
            helperText: 'From @BotFather. Stays on this device.',
            suffixIcon: IconButton(
              icon: Icon(_showToken ? Icons.visibility_off : Icons.visibility),
              onPressed: () => setState(() => _showToken = !_showToken),
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _chat,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Your Telegram chat id',
            helperText: 'Send /start to your bot and it tells you.',
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.network_check),
              label: Text(_busy ? 'Testing…' : 'Save and test'),
            ),
          ],
        ),
        if (_result != null) ...[
          const SizedBox(height: 12),
          _Result(text: _result!, ok: _ok),
        ],
        const Divider(height: 32),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Use this device as the Telegram hub'),
          subtitle: const Text(
              'This device collects what you send the bot, answers "done 2", and '
              'sends the digests. Turn it on for one device only, usually your '
              'phone, otherwise you will get everything twice.'),
          value: s.hubEnabled,
          onChanged: (v) async {
            if (v && !s.hubConfigured) await _save();
            await s.setHubEnabled(v);
            if (v && mounted) context.read<HubService>().tick();
          },
        ),
        Consumer<HubService>(
          builder: (context, hub, _) {
            if (!s.hubEnabled) return const SizedBox.shrink();
            final when = hub.lastRun;
            final line = hub.lastError ??
                (when == null
                    ? (s.hubConfigured ? 'Waiting for the first check…' : 'Fill in the four fields above.')
                    : 'Last check ${fmtWhen(when.toUtc())} · ${hub.lastMessage ?? 'done'}');
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line,
                  style: text.bodySmall?.copyWith(
                      color: hub.lastError != null ? cs.error : cs.onSurfaceVariant)),
            );
          },
        ),
        if (s.hubEnabled) ...[
          const SizedBox(height: 8),
          Text('Messages from this device', style: text.titleSmall),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Morning digest'),
            subtitle: const Text('Overdue, due today and coming up.'),
            value: s.digestEnabled,
            onChanged: s.setDigestEnabled,
          ),
          if (s.digestEnabled)
            DropdownButtonFormField<int>(
              key: ValueKey('dh${s.digestHour}'),
              initialValue: s.digestHour,
              decoration: const InputDecoration(labelText: 'Send at'),
              items: _hours(),
              onChanged: (v) => s.setDigestHour(v ?? 8),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Evening nudge'),
            subtitle: const Text('What is still open today.'),
            value: s.nudgeEnabled,
            onChanged: s.setNudgeEnabled,
          ),
          if (s.nudgeEnabled)
            DropdownButtonFormField<int>(
              key: ValueKey('nh${s.nudgeHour}'),
              initialValue: s.nudgeHour,
              decoration: const InputDecoration(labelText: 'Send at'),
              items: _hours(),
              onChanged: (v) => s.setNudgeHour(v ?? 17),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Weekly review'),
            subtitle: const Text('Done, slipped and the week ahead.'),
            value: s.weeklyEnabled,
            onChanged: s.setWeeklyEnabled,
          ),
          if (s.weeklyEnabled)
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('wd${s.weeklyDay}'),
                    initialValue: s.weeklyDay,
                    decoration: const InputDecoration(labelText: 'Day'),
                    items: [
                      for (var d = 1; d <= 7; d++)
                        DropdownMenuItem(value: d, child: Text(_days[d - 1])),
                    ],
                    onChanged: (v) => s.setWeeklyDay(v ?? DateTime.sunday),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    key: ValueKey('wh${s.weeklyHour}'),
                    initialValue: s.weeklyHour,
                    decoration: const InputDecoration(labelText: 'Time'),
                    items: _hours(),
                    onChanged: (v) => s.setWeeklyHour(v ?? 18),
                  ),
                ),
              ],
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Escalate overdue high-priority tasks'),
            subtitle: const Text(
                'For tasks marked !1: a message an hour after the due time, '
                'again after a day, and a stale warning after three.'),
            value: s.escalateEnabled,
            onChanged: s.setEscalateEnabled,
          ),
          Text(
            'Android checks about every 15 minutes while the app is closed, so '
            'messages can arrive a little after their set time.',
            style: muted,
          ),
        ],
      ],
    );
  }
}

/// Quiet hours: no reminders or Telegram messages in this window.
class QuietHoursSettings extends StatelessWidget {
  const QuietHoursSettings({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Keep quiet at night'),
          subtitle: const Text(
              'Reminders and Telegram messages wait until quiet hours end. A task '
              'marked !1 still reminds you at its due time.'),
          value: s.quietEnabled,
          onChanged: s.setQuietEnabled,
        ),
        if (s.quietEnabled) ...[
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey('qs${s.quietStart}'),
                  initialValue: s.quietStart,
                  decoration: const InputDecoration(labelText: 'From'),
                  items: _hours(),
                  onChanged: (v) => s.setQuietStart(v ?? 22),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  key: ValueKey('qe${s.quietEnd}'),
                  initialValue: s.quietEnd,
                  decoration: const InputDecoration(labelText: 'Until'),
                  items: _hours(),
                  onChanged: (v) => s.setQuietEnd(v ?? 7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Replies to messages you send the bot are never held.',
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}
