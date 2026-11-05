import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inkwell/core/setup_code.dart';
import 'package:inkwell/core/telegram.dart';
import 'package:inkwell/sync/github_setup.dart';

void main() {
  group('Telegram updates', () {
    test('keeps private text messages, drops groups and other updates', () {
      final list = TelegramApi.parseUpdates({
        'ok': true,
        'result': [
          {
            'update_id': 10,
            'message': {
              'chat': {'id': 555, 'type': 'private', 'first_name': 'Tushar'},
              'text': 'call Rahul friday 3pm'
            }
          },
          {
            'update_id': 11,
            'message': {
              'chat': {'id': -100, 'type': 'group'},
              'text': 'ignored'
            }
          },
          {'update_id': 12, 'edited_message': {}},
          {
            'update_id': 13,
            'message': {
              'chat': {'id': 555, 'type': 'private'},
              'caption': 'photo caption'
            }
          },
        ]
      });
      expect(list.map((u) => u.updateId), [10, 13]);
      expect(list.first.chatId, '555');
      expect(list.first.chatName, 'Tushar');
      expect(list.last.text, 'photo caption');
    });

    test('removes an old webhook and retries once on 409', () async {
      var calls = <String>[];
      final client = MockClient((req) async {
        final method = req.url.path.split('/').last;
        calls.add(method);
        if (method == 'getUpdates' && calls.where((c) => c == 'getUpdates').length == 1) {
          return http.Response(
              jsonEncode({'ok': false, 'error_code': 409, 'description': 'webhook'}), 409);
        }
        if (method == 'deleteWebhook') {
          return http.Response(jsonEncode({'ok': true, 'result': true}), 200);
        }
        return http.Response(jsonEncode({'ok': true, 'result': []}), 200);
      });
      final out = await TelegramApi('123:abc', client: client).getUpdates();
      expect(out, isEmpty);
      expect(calls, ['getUpdates', 'deleteWebhook', 'getUpdates']);
    });

    test('a bad token is explained', () async {
      final client = MockClient((_) async =>
          http.Response(jsonEncode({'ok': false, 'error_code': 401}), 401));
      expect(
        () => TelegramApi('bad', client: client).getMe(),
        throwsA(isA<HubException>()),
      );
    });
  });

  group('SetupCode', () {
    test('round trip and wrong PIN', () async {
      final code = await SetupCode.encode({'v': 1, 'tg': {'token': 'x'}}, 'secret1');
      expect(code.startsWith(SetupCode.prefix), isTrue);
      final back = await SetupCode.decode(code, 'secret1');
      expect((back['tg'] as Map)['token'], 'x');
      expect(() => SetupCode.decode(code, 'nope-nope'),
          throwsA(isA<SetupCodeException>()));
    });

    test('rejects short PINs and junk', () async {
      expect(() => SetupCode.encode({}, '123'), throwsA(isA<SetupCodeException>()));
      expect(() => SetupCode.decode('hello', '123456'), throwsA(isA<SetupCodeException>()));
      expect(() => SetupCode.decode('INKWELL1.AAAA', '123456'),
          throwsA(isA<SetupCodeException>()));
    });

    test('tolerates line breaks added by chat apps', () async {
      final code = await SetupCode.encode({'v': 1}, 'secret1');
      final broken = '${code.substring(0, 20)}\n ${code.substring(20)}';
      expect((await SetupCode.decode(broken, 'secret1'))['v'], 1);
    });
  });

  group('GitHubSetup', () {
    test('creates a private repo', () async {
      late Map body;
      final client = MockClient((req) async {
        body = jsonDecode(req.body) as Map;
        return http.Response(jsonEncode({'full_name': 'me/inkwell-sync'}), 201);
      });
      final name = await GitHubSetup('t', client: client).createPrivateRepo();
      expect(name, 'me/inkwell-sync');
      expect(body['private'], true);
    });

    test('reuses an existing repo on 422', () async {
      final client = MockClient((req) async {
        if (req.method == 'POST') return http.Response('{}', 422);
        if (req.url.path == '/user') return http.Response(jsonEncode({'login': 'me'}), 200);
        return http.Response('{}', 200);
      });
      expect(await GitHubSetup('t', client: client).createPrivateRepo(), 'me/inkwell-sync');
    });

    test('explains a token that cannot create repos', () async {
      final client = MockClient((_) async => http.Response('{}', 403));
      expect(() => GitHubSetup('t', client: client).createPrivateRepo(),
          throwsA(isA<RepoSetupException>()));
    });

    test('generated passphrases are long and distinct', () {
      final a = GitHubSetup.generatePassphrase(random: Random(1));
      final b = GitHubSetup.generatePassphrase(random: Random(2));
      expect(a.length, 24);
      expect(a, isNot(b));
    });
  });
}
