import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class HubException implements Exception {
  HubException(this.message);
  final String message;
  @override
  String toString() => message;
}


/// A message the owner sent to the bot, read straight from Telegram.
class TgUpdate {
  const TgUpdate(this.updateId, this.chatId, this.text, {this.chatName = ''});
  final int updateId;
  final String chatId;
  final String text;
  final String chatName;
}

/// Talks to Telegram with a bot token: checks the token, finds the owner's
/// chat id and reads incoming messages (no server needed).
class TelegramApi {
  TelegramApi(this.token, {http.Client? client}) : _http = client ?? http.Client();

  final String token;
  final http.Client _http;

  Future<Map<String, dynamic>> _call(String method, [Map<String, dynamic>? body]) async {
    http.Response r;
    try {
      r = await _http
          .post(
            Uri.https('api.telegram.org', '/bot${token.trim()}/$method'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body ?? const {}),
          )
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw HubException('Telegram did not answer in time.');
    } catch (e) {
      throw HubException('Could not reach Telegram: $e');
    }
    Map<String, dynamic> j;
    try {
      j = jsonDecode(r.body) as Map<String, dynamic>;
    } catch (_) {
      throw HubException('Telegram sent an unexpected reply (${r.statusCode}).');
    }
    if (j['ok'] != true) {
      final code = (j['error_code'] as num?)?.toInt() ?? r.statusCode;
      if (code == 401 || code == 404) {
        throw HubException('Telegram rejected the bot token. Copy it again from @BotFather.');
      }
      if (code == 409) throw _WebhookActive();
      throw HubException('Telegram: ${j['description'] ?? 'error $code'}');
    }
    return j;
  }

  /// The bot's @username. Throws [HubException] if the token is wrong.
  Future<String> getMe() async {
    final j = await _call('getMe');
    final res = (j['result'] as Map).cast<String, dynamic>();
    return (res['username'] as String?) ?? 'your bot';
  }

  Future<void> deleteWebhook() => _call('deleteWebhook', {'drop_pending_updates': false});

  /// Messages after [offset] (pass lastUpdateId + 1). If an old webhook is
  /// still set, it is removed first and the call retried once.
  Future<List<TgUpdate>> getUpdates({int offset = 0}) async {
    Map<String, dynamic> j;
    try {
      j = await _call('getUpdates', {
        if (offset > 0) 'offset': offset,
        'timeout': 0,
        'limit': 100,
        'allowed_updates': ['message'],
      });
    } on _WebhookActive {
      await deleteWebhook();
      j = await _call('getUpdates', {
        if (offset > 0) 'offset': offset,
        'timeout': 0,
        'limit': 100,
        'allowed_updates': ['message'],
      });
    }
    return parseUpdates(j);
  }

  /// The chat that most recently messaged the bot (private chats only).
  Future<TgUpdate?> latestChat() async {
    final all = await getUpdates();
    return all.isEmpty ? null : all.last;
  }

  /// Pure parser, kept separate so it can be tested.
  static List<TgUpdate> parseUpdates(Map<String, dynamic> j) {
    final out = <TgUpdate>[];
    for (final u in (j['result'] as List? ?? const [])) {
      if (u is! Map) continue;
      final id = (u['update_id'] as num?)?.toInt();
      final m = u['message'];
      if (id == null || m is! Map) continue;
      final chat = m['chat'];
      if (chat is! Map || chat['type'] != 'private') continue;
      final text = (m['text'] as String?) ?? (m['caption'] as String?) ?? '';
      final first = (chat['first_name'] as String?) ?? '';
      final user = (chat['username'] as String?) ?? '';
      out.add(TgUpdate(id, '${chat['id']}', text,
          chatName: first.isNotEmpty ? first : user));
    }
    return out;
  }
}

class _WebhookActive extends HubException {
  _WebhookActive() : super('A webhook is set on this bot.');
}

/// Sends messages to the owner's Telegram chat with the bot token stored on
/// this device. (The bot server never needs to know what a digest says.)
class TelegramClient {
  TelegramClient({required this.token, required this.chatId, http.Client? client})
      : _http = client ?? http.Client();

  final String token;
  final String chatId;
  final http.Client _http;

  static const int _limit = 4000;

  /// Sends [text], splitting it at line breaks if it is long. True on success.
  Future<bool> send(String text) async {
    for (final part in _chunks(text)) {
      try {
        final r = await _http.post(
          Uri.https('api.telegram.org', '/bot$token/sendMessage'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'chat_id': chatId,
            'text': part,
            'disable_web_page_preview': true,
          }),
        ).timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  static List<String> _chunks(String text) {
    if (text.length <= _limit) return [text];
    final out = <String>[];
    var buf = StringBuffer();
    for (final line in text.split('\n')) {
      if (buf.length + line.length + 1 > _limit && buf.isNotEmpty) {
        out.add(buf.toString());
        buf = StringBuffer();
      }
      buf.writeln(line.length > _limit ? line.substring(0, _limit) : line);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }
}

/// One thing waiting in the bot's inbox: a Telegram message or a screened email.
class InboxItem {
  const InboxItem({
    required this.id,
    required this.kind,
    this.text = '',
    this.title = '',
    this.body = '',
    this.from = '',
    this.link = '',
    this.due,
    this.priority = 0,
  });

  final String id;

  /// "message" (from Telegram) or "mail".
  final String kind;
  final String text;
  final String title;
  final String body;
  final String from;
  final String link;
  final DateTime? due;
  final int priority;

  factory InboxItem.fromJson(Map<String, dynamic> j) {
    DateTime? due;
    final raw = j['due'];
    if (raw is String && raw.isNotEmpty) {
      final d = DateTime.tryParse(raw);
      if (d != null) due = DateTime(d.year, d.month, d.day); // a date, no time
    }
    return InboxItem(
      id: '${j['id']}',
      kind: (j['kind'] as String?) ?? 'message',
      text: (j['text'] as String?) ?? '',
      title: (j['title'] as String?) ?? '',
      body: (j['body'] as String?) ?? '',
      from: (j['from'] as String?) ?? '',
      link: (j['link'] as String?) ?? '',
      due: due,
      priority: ((j['priority'] as num?)?.toInt() ?? 0).clamp(0, 3),
    );
  }
}

/// Reads and clears the inbox on the Vercel bot.
class BotInbox {
  BotInbox({required String baseUrl, required this.key, http.Client? client})
      : base = baseUrl.trim().replaceAll(RegExp(r'/+$'), ''),
        _http = client ?? http.Client();

  final String base;
  final String key;
  final http.Client _http;

  Map<String, String> get _headers =>
      {'Authorization': 'Bearer $key', 'Content-Type': 'application/json'};

  Future<List<InboxItem>> fetch() async {
    final r = await _call(() => _http.get(Uri.parse('$base/api/inbox'), headers: _headers));
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return [
      for (final i in (j['items'] as List? ?? const []))
        InboxItem.fromJson((i as Map).cast<String, dynamic>())
    ];
  }

  Future<void> ack(List<String> ids) async {
    if (ids.isEmpty) return;
    await _call(() => _http.post(Uri.parse('$base/api/inbox'),
        headers: _headers, body: jsonEncode({'ack': ids})));
  }

  Future<http.Response> _call(Future<http.Response> Function() go) async {
    http.Response r;
    try {
      r = await go().timeout(const Duration(seconds: 25));
    } on TimeoutException {
      throw HubException('The bot did not answer in time.');
    } catch (e) {
      throw HubException('Could not reach the bot: $e');
    }
    if (r.statusCode == 401) {
      throw HubException('The bot rejected the key. Check the Inkwell key matches INKWELL_KEY on Vercel.');
    }
    if (r.statusCode == 404) {
      throw HubException('Bot address not found. It should look like https://your-project.vercel.app');
    }
    if (r.statusCode != 200) {
      throw HubException('The bot returned an error (${r.statusCode}).');
    }
    return r;
  }
}
