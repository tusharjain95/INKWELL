import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'digest.dart';
import 'models.dart';
import 'nlp.dart';
import 'settings.dart';
import 'store.dart';
import 'telegram.dart';

/// A reply the user can type to the Telegram bot instead of a new task.
class HubCommand {
  const HubCommand(this.kind, {this.numbers = const [], this.rest = ''});

  /// done, snooze, list or help.
  final String kind;
  final List<int> numbers;
  final String rest;
}

final RegExp _reDone = RegExp(
    r'^/?done(?:@\w+)?\s+\d+(?:\s*(?:,|&|and)?\s*\d+)*\s*$',
    caseSensitive: false);
final RegExp _reSnooze =
    RegExp(r'^/?snooze(?:@\w+)?\s+(\d+)(?:\s+(.+))?$', caseSensitive: false, dotAll: true);
final RegExp _reList = RegExp(r'^/?(?:list|today|tasks|digest)(?:@\w+)?$', caseSensitive: false);
final RegExp _reHelp = RegExp(r'^/?(?:help|\?)(?:@\w+)?$', caseSensitive: false);

/// Recognises "done 2 3", "snooze 2 tomorrow 5pm", "list" and "help".
/// Anything else (including "done with the audit") is a new task or note.
HubCommand? parseHubCommand(String text) {
  final t = text.trim();
  if (_reDone.hasMatch(t)) {
    final nums = RegExp(r'\d+').allMatches(t).map((m) => int.parse(m.group(0)!)).toList();
    if (nums.isNotEmpty) return HubCommand('done', numbers: nums);
  }
  final s = _reSnooze.firstMatch(t);
  if (s != null) {
    return HubCommand('snooze', numbers: [int.parse(s.group(1)!)], rest: (s.group(2) ?? '').trim());
  }
  if (_reList.hasMatch(t)) return const HubCommand('list');
  if (_reHelp.hasMatch(t)) return const HubCommand('help');
  return null;
}

const String kHubHelp = 'Send me anything to save it, for example:\n'
    '  call Rahul tomorrow 5pm !1\n'
    '  note: GST login hint\n\n'
    'Then:\n'
    '  list → today\'s tasks\n'
    '  done 2 → tick task 2 from the latest list\n'
    '  snooze 2 friday 10am → move it\n\n'
    'Numbers refer to the latest list I sent.';

/// Turns inbox items and commands into changes in the note store.
class HubHandler {
  HubHandler({
    required this.store,
    required this.reply,
    required this.cfg,
    required this.dayFirst,
    List<String>? lastList,
    DateTime Function()? clock,
  })  : lastList = lastList ?? [],
        _clock = clock ?? DateTime.now;

  final NoteStore store;
  final Future<bool> Function(String text) reply;
  final DigestConfig cfg;
  final bool dayFirst;
  final DateTime Function() _clock;

  /// Note ids behind the numbers in the latest list; updated by "list".
  List<String> lastList;

  String _title(Note n) => n.title.trim().isEmpty ? 'Untitled' : n.title.trim();

  Future<void> handle(InboxItem item) async {
    if (item.kind == 'mail') return _mail(item);
    return _message(item.text);
  }

  Future<void> _message(String text) async {
    final cmd = parseHubCommand(text);
    if (cmd != null) return _command(cmd);

    final e = parseEntry(text.trim(), now: _clock(), dayFirst: dayFirst);
    if (e.isEmpty) {
      await reply('I could not find anything to save in that message.');
      return;
    }
    final n = await store.createFromEntry(e);
    if (n.isTask) {
      final d = n.due;
      await reply('✅ Task added: ${_title(n)}${d == null ? '' : ' · ${fmtDue(d, n.dueHasTime)}'}');
    } else {
      await reply('📝 Note added: ${_title(n)}');
    }
  }

  Future<void> _mail(InboxItem m) async {
    final body = StringBuffer(m.body.trim());
    if (m.from.isNotEmpty) body.write('\n\nFrom: ${m.from}');
    if (m.link.isNotEmpty) body.write('\n${m.link}');
    final n = await store.createFromEntry(ParsedEntry(
      title: m.title.trim().isEmpty ? '(email)' : m.title.trim(),
      body: body.toString().trim(),
      due: m.due,
      hasTime: false,
      priority: m.priority,
      tags: ['email'],
      isTask: true,
    ));
    final d = n.due;
    await reply('📧 Task from email: ${_title(n)}${d == null ? '' : ' · due ${fmtDay(d)}'}'
        '${n.priority == 1 ? ' ❗' : ''}');
  }

  Note? _byNumber(int n) {
    if (n < 1 || n > lastList.length) return null;
    final note = store.byId(lastList[n - 1]);
    return (note == null || note.deleted) ? null : note;
  }

  Future<void> _command(HubCommand c) async {
    switch (c.kind) {
      case 'help':
        await reply(kHubHelp);
      case 'list':
        {
          final m = buildDigest(_clock(), store.all, cfg, always: true)!;
          lastList = List<String>.from(m.ids);
          await reply(m.text);
        }
      case 'done':
        {
          await _done(c);
        }
      case 'snooze':
        {
          await _snooze(c);
        }
    }
  }

  Future<void> _done(HubCommand c) async {
    if (lastList.isEmpty) {
      await reply('Send "list" first so I know which numbers you mean.');
      return;
    }
    final lines = <String>[];
    for (final k in c.numbers) {
      final n = _byNumber(k);
      if (n == null) {
        lines.add('No item $k in the latest list.');
        continue;
      }
      if (n.done) {
        lines.add('Already done: ${_title(n)}');
        continue;
      }
      await store.toggleDone(n.id);
      final after = store.byId(n.id);
      if (after != null && !after.done && after.due != null) {
        lines.add('🔁 ${_title(n)} · next ${fmtDue(after.due!, after.dueHasTime)}');
      } else {
        lines.add('✅ Done: ${_title(n)}');
      }
    }
    await reply(lines.join('\n'));
  }

  Future<void> _snooze(HubCommand c) async {
    if (lastList.isEmpty) {
      await reply('Send "list" first so I know which numbers you mean.');
      return;
    }
    final n = _byNumber(c.numbers.first);
    if (n == null) {
      await reply('No item ${c.numbers.first} in the latest list.');
      return;
    }
    final now = _clock();
    DateTime? due;
    var hasTime = n.dueHasTime;
    if (c.rest.isNotEmpty) {
      final p = parseEntry(c.rest, now: now, dayFirst: dayFirst);
      due = p.due;
      if (due != null) hasTime = p.hasTime;
    }
    if (due == null) {
      // No usable date given: the same time tomorrow.
      final base = n.due ?? now;
      due = DateTime(base.year, base.month, base.day + 1, base.hour, base.minute);
      if (!n.dueHasTime) due = DateTime(due.year, due.month, due.day);
    }
    await store.save(n.copyWith(due: due, dueHasTime: hasTime, updatedAt: now.toUtc()));
    await reply('⏭ ${_title(n)} · now ${fmtDue(due, hasTime)}');
  }
}

/// Runs the Telegram and email side of Inkwell on one device: collects what
/// arrived at the bot, answers replies, and sends digests and nudges.
///
/// Enable it on one device only (usually the phone). Several devices would
/// each send their own digest and split the incoming items between them.
class HubService extends ChangeNotifier {
  HubService(this.store, this.settings, {http.Client? client, DateTime Function()? clock})
      : _client = client,
        _clock = clock ?? DateTime.now;

  final NoteStore store;
  final AppSettings settings;
  final http.Client? _client;
  final DateTime Function() _clock;

  bool running = false;
  String? lastError;
  String? lastMessage;
  DateTime? lastRun;
  Timer? _timer;

  static const String _kState = 'hub.state';
  static const String _kSeen = 'hub.seen';
  static const String _kOffset = 'hub.tg.offset';

  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 2), (_) => tick());
    Timer(const Duration(seconds: 6), tick);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  TelegramClient _telegram() => TelegramClient(
      token: settings.telegramToken, chatId: settings.telegramChat, client: _client);
  TelegramApi _api() => TelegramApi(settings.telegramToken, client: _client);
  BotInbox _bot() =>
      BotInbox(baseUrl: settings.botUrl, key: settings.botKey, client: _client);

  Set<String> _loadSeen() {
    try {
      return (jsonDecode(settings.getString(_kSeen) ?? '[]') as List).map((e) => '$e').toSet();
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveSeen(Set<String> seen) async {
    final list = seen.toList();
    final keep = list.length > 300 ? list.sublist(list.length - 300) : list;
    await settings.putString(_kSeen, jsonEncode(keep));
  }

  /// Checks the connection and sends a hello. Throws [HubException] with the reason.
  Future<String> test() async {
    final name = await _api().getMe();
    var waiting = 0;
    String relay = '';
    if (settings.botConfigured) {
      try {
        waiting = (await _bot().fetch()).length;
        relay = ' Email relay reachable ($waiting waiting).';
      } on HubException catch (e) {
        relay = ' Email relay: ${e.message}';
      }
    }
    final ok = await _telegram().send('Inkwell is connected ✓');
    if (!ok) {
      throw HubException('@$name is a valid bot, but Telegram refused the message. '
          'Open the bot in Telegram, press Start, then try again.');
    }
    return 'Connected to @$name. A confirmation was sent to your Telegram.$relay';
  }

  /// One round: collect the inbox, then send whatever is due.
  Future<void> tick() async {
    if (running || !settings.hubReady) return;
    running = true;
    lastError = null;
    notifyListeners();
    try {
      await settings.refresh();
      final tg = _telegram();
      final cfg = settings.digestConfig;
      final state = HubState.fromJson(settings.getString(_kState));
      final handler = HubHandler(
        store: store,
        reply: tg.send,
        cfg: cfg,
        dayFirst: settings.dayFirstDates,
        lastList: state.lastList,
        clock: _clock,
      );

      var handled = 0;
      final seen = _loadSeen();

      // 1. Messages sent to the bot, read straight from Telegram.
      final lastOffset = int.tryParse(settings.getString(_kOffset) ?? '') ?? 0;
      final updates = await _api().getUpdates(offset: lastOffset > 0 ? lastOffset + 1 : 0);
      var maxId = lastOffset;
      for (final u in updates) {
        if (u.updateId > maxId) maxId = u.updateId;
        // Only the owner's chat may add things.
        if (u.chatId != settings.telegramChat.trim() || u.text.trim().isEmpty) continue;
        final id = 'tg${u.updateId}';
        if (seen.contains(id)) continue;
        try {
          await handler.handle(InboxItem(id: id, kind: 'message', text: u.text));
          handled++;
        } catch (e) {
          await tg.send('⚠️ I could not save that: $e');
        }
        seen.add(id);
      }
      if (maxId > lastOffset) await settings.putString(_kOffset, '$maxId');

      // 2. Screened email (and anything still queued on an old bot).
      if (settings.botConfigured) {
        final items = await _bot().fetch();
        final toAck = <String>[];
        for (final it in items) {
          if (!seen.contains(it.id)) {
            try {
              await handler.handle(it);
              handled++;
            } catch (e) {
              await tg.send('⚠️ I could not save that: $e');
            }
            seen.add(it.id);
          }
          toAck.add(it.id);
        }
        await _saveSeen(seen);
        state.lastList = handler.lastList;
        await settings.putString(_kState, state.toJson());
        await _bot().ack(toAck);
      } else {
        await _saveSeen(seen);
        state.lastList = handler.lastList;
        await settings.putString(_kState, state.toJson());
      }

      final plan = planHubMessages(
        now: _clock(),
        notes: store.all,
        cfg: cfg,
        state: state,
      );
      var sent = 0;
      var allSent = true;
      final next = plan.state;
      next.lastList = handler.lastList;
      for (final m in plan.messages) {
        if (!await tg.send(m.text)) {
          allSent = false;
          break;
        }
        sent++;
        if (m.ids.isNotEmpty) next.lastList = m.ids;
      }
      // If Telegram was unreachable, keep the old markers so it is retried.
      await settings.putString(_kState, (allSent ? next : state).toJson());

      lastRun = _clock();
      lastMessage = [
        if (handled > 0) '$handled received',
        if (sent > 0) '$sent sent',
        if (handled == 0 && sent == 0) 'nothing new',
      ].join(' · ');
    } on HubException catch (e) {
      lastError = e.message;
    } catch (e) {
      lastError = 'Telegram hub failed: $e';
    } finally {
      running = false;
      notifyListeners();
    }
  }
}
