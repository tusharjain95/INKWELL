import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:inkwell/core/models.dart';
import 'package:inkwell/core/nlp.dart';
import 'package:inkwell/core/settings.dart';
import 'package:inkwell/core/store.dart';
import 'package:inkwell/sync/drive_auth.dart';
import 'package:inkwell/sync/drive_client.dart';
import 'package:inkwell/sync/drive_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An in-memory stand-in for the Drive v3 endpoints Inkwell uses.
class FakeDrive {
  final Map<String, ({String name, Uint8List bytes, int version, DateTime created})> files = {};
  int _n = 0;
  int calls = 0;

  DriveClient client() {
    final auth = DriveAuth(client: MockClient((r) async => http.Response(
        jsonEncode({'access_token': 't', 'expires_in': 3600}), 200)));
    return DriveClient(DriveTokenSource(auth, 'refresh'), client: MockClient(_handle));
  }

  Map<String, dynamic> _meta(String id) {
    final f = files[id]!;
    return {
      'id': id,
      'name': f.name,
      'md5Checksum': 'v${f.version}',
      'modifiedTime': DateTime.now().toUtc().toIso8601String(),
      'createdTime': f.created.toUtc().toIso8601String(),
    };
  }

  Future<http.Response> _handle(http.Request r) async {
    calls++;
    final path = r.url.path;
    final q = r.url.queryParameters;
    if (r.method == 'GET' && path == '/drive/v3/files') {
      return http.Response(
          jsonEncode({'files': [for (final id in files.keys) _meta(id)]}), 200);
    }
    if (r.method == 'GET' && path.startsWith('/drive/v3/files/')) {
      final id = path.split('/').last;
      if (!files.containsKey(id)) return http.Response('{"error":{"message":"nf"}}', 404);
      if (q['alt'] == 'media') return http.Response.bytes(files[id]!.bytes, 200);
      return http.Response(jsonEncode({'md5Checksum': 'v${files[id]!.version}'}), 200);
    }
    if (r.method == 'POST' && path == '/upload/drive/v3/files') {
      final body = latin1.decode(r.bodyBytes);
      final name = RegExp(r'"name":"([^"]+)"').firstMatch(body)!.group(1)!;
      final start = body.indexOf('\r\n\r\n', body.indexOf('application/octet-stream')) + 4;
      final end = body.lastIndexOf('\r\n--');
      final id = 'id${++_n}';
      files[id] = (
        name: name,
        bytes: Uint8List.fromList(r.bodyBytes.sublist(start, end)),
        version: 1,
        created: DateTime.now().subtract(const Duration(hours: 1)),
      );
      return http.Response(jsonEncode(_meta(id)), 200);
    }
    if (r.method == 'PATCH' && path.startsWith('/upload/drive/v3/files/')) {
      final id = path.split('/').last;
      final old = files[id]!;
      files[id] = (
        name: old.name,
        bytes: Uint8List.fromList(r.bodyBytes),
        version: old.version + 1,
        created: old.created,
      );
      return http.Response(jsonEncode(_meta(id)), 200);
    }
    if (r.method == 'DELETE') {
      files.remove(path.split('/').last);
      return http.Response('', 204);
    }
    return http.Response('unexpected ${r.method} $path', 500);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('multipart body', () {
    test('contains metadata, bytes and closing boundary', () {
      final body = DriveClient.buildMultipart(
          'B', {'name': 'x', 'parents': ['appDataFolder']}, Uint8List.fromList([1, 2, 3]));
      final s = latin1.decode(body);
      expect(s.startsWith('--B\r\nContent-Type: application/json'), isTrue);
      expect(s.contains('"parents":["appDataFolder"]'), isTrue);
      expect(s.endsWith('\r\n--B--'), isTrue);
      expect(body.contains(3), isTrue);
    });
  });

  group('DriveClient', () {
    test('lists every page', () async {
      var page = 0;
      final auth = DriveAuth(client: MockClient((r) async => http.Response(
          jsonEncode({'access_token': 't', 'expires_in': 3600}), 200)));
      final c = DriveClient(
        DriveTokenSource(auth, 'r'),
        client: MockClient((r) async {
          page++;
          if (page == 1) {
            return http.Response(
                jsonEncode({
                  'nextPageToken': 'p2',
                  'files': [
                    {'id': '1', 'name': 'a', 'md5Checksum': 'x'}
                  ]
                }),
                200);
          }
          expect(r.url.queryParameters['pageToken'], 'p2');
          return http.Response(
              jsonEncode({
                'files': [
                  {'id': '2', 'name': 'b', 'md5Checksum': 'y'}
                ]
              }),
              200);
        }),
      );
      final files = await c.list();
      expect(files.map((f) => f.name), ['a', 'b']);
    });

    test('refreshes the token once on a 401 and retries', () async {
      var tokenCalls = 0;
      final auth = DriveAuth(client: MockClient((r) async {
        tokenCalls++;
        return http.Response(
            jsonEncode({'access_token': 'tok$tokenCalls', 'expires_in': 3600}), 200);
      }));
      var apiCalls = 0;
      final c = DriveClient(
        DriveTokenSource(auth, 'r'),
        client: MockClient((r) async {
          apiCalls++;
          if (apiCalls == 1) return http.Response('{}', 401);
          expect(r.headers['Authorization'], 'Bearer tok2');
          return http.Response(jsonEncode({'files': []}), 200);
        }),
      );
      expect(await c.list(), isEmpty);
      expect(tokenCalls, 2);
    });

    test('deleting a file that is already gone is not an error', () async {
      final auth = DriveAuth(client: MockClient((r) async => http.Response(
          jsonEncode({'access_token': 't', 'expires_in': 3600}), 200)));
      final c = DriveClient(DriveTokenSource(auth, 'r'),
          client: MockClient((r) async => http.Response('{}', 404)));
      await c.delete('x');
    });
  });

  group('DriveAuth', () {
    test('waits through "pending" until approved', () async {
      var n = 0;
      final auth = DriveAuth(client: MockClient((r) async {
        if (r.url.path.endsWith('/device/code')) {
          return http.Response(
              jsonEncode({
                'device_code': 'dc',
                'user_code': 'ABCD-EFGH',
                'verification_url': 'https://www.google.com/device',
                'expires_in': 600,
                'interval': 0,
              }),
              200);
        }
        n++;
        if (n < 3) return http.Response(jsonEncode({'error': 'authorization_pending'}), 428);
        return http.Response(
            jsonEncode({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600}), 200);
      }));
      // Credentials are compile-time values; start() refuses without them.
      if (!DriveAuth.configured) {
        expect(auth.start(), throwsA(isA<DriveAuthException>()));
        return;
      }
      final code = await auth.start();
      expect(code.userCode, 'ABCD-EFGH');
      final t = await auth.waitForApproval(code);
      expect(t.refreshToken, 'r');
    });

    test('an expired refresh token asks the user to sign in again', () async {
      final auth = DriveAuth(
          client: MockClient((r) async => http.Response(jsonEncode({'error': 'invalid_grant'}), 400)));
      await expectLater(
        auth.refresh('old'),
        throwsA(isA<DriveAuthException>().having((e) => e.needsSignIn, 'needsSignIn', true)),
      );
    });
  });

  group('DriveSync between two devices', () {
    late Directory dirA, dirB;
    late NoteStore a, b;
    late DriveSync syncA, syncB;
    late FakeDrive drive;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      dirA = await Directory.systemTemp.createTemp('inkwell_a_');
      dirB = await Directory.systemTemp.createTemp('inkwell_b_');
      a = await NoteStore.open(rootOverride: dirA);
      b = await NoteStore.open(rootOverride: dirB);
      final settings = await AppSettings.load();
      syncA = DriveSync(a, settings, passphrase: () => 'correct horse');
      syncB = DriveSync(b, settings, passphrase: () => 'correct horse');
      drive = FakeDrive();
    });

    tearDown(() async {
      await dirA.delete(recursive: true);
      await dirB.delete(recursive: true);
    });

    test('a note, then a ticked task, travel both ways', () async {
      final task = await a.createFromEntry(ParsedEntry(title: 'Call Rahul', isTask: true));
      final r1 = await syncA.syncOnce(client: drive.client());
      expect(r1.pushed, 1);
      expect(drive.files.values.map((f) => f.name), containsAll(['meta.json', 'n_${task.id}.enc']));

      final r2 = await syncB.syncOnce(client: drive.client());
      expect(r2.pulled, 1);
      expect(b.byId(task.id)?.title, 'Call Rahul');
      expect(b.byId(task.id)?.done, isFalse);

      await b.toggleDone(task.id);
      await syncB.syncOnce(client: drive.client());
      await syncA.syncOnce(client: drive.client());
      expect(a.byId(task.id)?.done, isTrue);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a wrong passphrase is rejected and nothing is overwritten', () async {
      await a.createFromEntry(ParsedEntry(title: 'x', body: 'y'));
      await syncA.syncOnce(client: drive.client());
      final settings = await AppSettings.load();
      final wrong = DriveSync(b, settings, passphrase: () => 'nope');
      await expectLater(wrong.syncOnce(client: drive.client()), throwsA(anything));
      expect(b.all, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('an unchanged drive is not re-downloaded', () async {
      await a.createFromEntry(ParsedEntry(title: 'x', body: 'y'));
      await syncA.syncOnce(client: drive.client());
      await syncA.syncOnce(client: drive.client()); // records the listing
      final before = drive.calls;
      final r = await syncA.syncOnce(client: drive.client());
      expect(r.upToDate, isTrue);
      expect(drive.calls - before, 1); // just the listing
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('an attachment uploads once and downloads on the other device', () async {
      final f = File('${dirA.path}/pic.txt')..writeAsStringSync('hello attachment');
      final n = await a.createFromEntry(ParsedEntry(title: 'with file', body: 'b'));
      final imported = await a.importAttachment(f, 'pic.txt');
      await a.save(n.copyWith(
          attachments: [imported.ref], updatedAt: DateTime.now().toUtc()));
      final r = await syncA.syncOnce(client: drive.client());
      expect(r.uploads, 1);
      await syncB.syncOnce(client: drive.client());
      final got = await syncB.ensureAttachment(imported.ref, client: drive.client());
      expect(await got.readAsString(), 'hello attachment');
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
