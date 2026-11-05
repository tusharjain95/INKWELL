import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class HubException implements Exception {
  HubException(this.message);
  final String message;
  @override
  String toString() => message;
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
