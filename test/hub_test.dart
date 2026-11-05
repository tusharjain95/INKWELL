import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/digest.dart';
import 'package:inkwell/core/hub.dart';
import 'package:inkwell/core/models.dart';
import 'package:inkwell/core/nlp.dart';
import 'package:inkwell/core/store.dart';
import 'package:inkwell/core/telegram.dart';

ParsedEntry todayTask(String title) =>
    ParsedEntry(title: title, due: DateTime(2026, 11, 5), isTask: true);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parseHubCommand', () {
    test('reads done with several numbers', () {
      expect(parseHubCommand('done 2')!.numbers, [2]);
      expect(parseHubCommand('/done 1 3 5')!.numbers, [1, 3, 5]);
      expect(parseHubCommand('Done 1, 2 and 4')!.numbers, [1, 2, 4]);
      expect(parseHubCommand('/done@MyBot 7')!.numbers, [7]);
    });

    test('reads snooze with a date', () {
      final c = parseHubCommand('snooze 2 friday 10am')!;
      expect(c.kind, 'snooze');
      expect(c.numbers, [2]);
      expect(c.rest, 'friday 10am');
      expect(parseHubCommand('/snooze 3')!.rest, '');
    });

    test('reads list and help', () {
      for (final t in ['list', '/list', 'Today', '/tasks', '/digest@MyBot']) {
        expect(parseHubCommand(t)!.kind, 'list', reason: t);
      }
      expect(parseHubCommand('help')!.kind, 'help');
      expect(parseHubCommand('?')!.kind, 'help');
    });

    test('ordinary sentences are not commands', () {
      for (final t in [
        'done with the audit',
        'done',
        'call Rahul tomorrow',
        'snooze button redesign',
        'list of documents to collect',
        'today I met Anil',
      ]) {
        expect(parseHubCommand(t), isNull, reason: t);
      }
    });
  });

  group('InboxItem', () {
    test('reads a date-only due date and clamps priority', () {
      final i = InboxItem.fromJson({
        'id': 'x',
        'kind': 'mail',
        'title': 'Notice',
        'due': '2026-11-30',
        'priority': 9,
      });
      expect(i.due, DateTime(2026, 11, 30));
      expect(i.priority, 3);
      expect(InboxItem.fromJson({'id': 'y'}).kind, 'message');
    });
  });

  group('HubHandler', () {
    late Directory dir;
    late NoteStore store;
    late List<String> said;
    late HubHandler h;
    final fixed = DateTime(2026, 11, 5, 9, 0); // Thursday

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('inkwell_hub_');
      store = await NoteStore.open(rootOverride: dir);
      said = [];
      h = HubHandler(
        store: store,
        reply: (t) async {
          said.add(t);
          return true;
        },
        cfg: const DigestConfig(),
        dayFirst: true,
        clock: () => fixed,
      );
    });

    tearDown(() async => dir.delete(recursive: true));

    test('a message becomes a task with a due date and priority', () async {
      await h.handle(const InboxItem(id: '1', kind: 'message', text: 'call Rahul tomorrow 5pm !1'));
      final n = store.all.single;
      expect(n.isTask, isTrue);
      expect(n.priority, 1);
      expect(n.due, DateTime(2026, 11, 6, 17));
      expect(said.single, contains('Task added'));
      expect(said.single, contains('Fri 6 Nov 17:00'));
    });

    test('a message that is not a task becomes a note', () async {
      await h.handle(const InboxItem(id: '1', kind: 'message', text: 'note: GST portal hint is the pet name'));
      expect(store.all.single.isTask, isFalse);
      expect(said.single, contains('Note added'));
    });

    test('an email becomes a high-priority task with the link in the body', () async {
      await h.handle(InboxItem(
        id: '2',
        kind: 'mail',
        title: 'IT Dept: Notice u/s 143(1)',
        body: 'Respond within 15 days.',
        from: 'IT Dept <a@incometax.gov.in>',
        link: 'https://mail.google.com/mail/u/0/#inbox/abc',
        due: DateTime(2026, 11, 30),
        priority: 1,
      ));
      final n = store.all.single;
      expect(n.isTask, isTrue);
      expect(n.priority, 1);
      expect(n.due, DateTime(2026, 11, 30));
      expect(n.dueHasTime, isFalse);
      expect(n.plain, contains('mail.google.com'));
      expect(n.tags, contains('email'));
      expect(said.single, contains('Task from email'));
    });

    test('list, then done and snooze use the numbers of the latest list', () async {
      final a = await store.createFromEntry(todayTask('Panamax GST'));
      final b = await store.createFromEntry(todayTask('Uday case'));
      await h.handle(const InboxItem(id: '3', kind: 'message', text: 'list'));
      expect(h.lastList.toSet(), {a.id, b.id});
      expect(said.last, contains('Today (2)'));

      final first = h.lastList[0];
      await h.handle(const InboxItem(id: '4', kind: 'message', text: 'done 1'));
      expect(store.byId(first)!.done, isTrue);
      expect(said.last, contains('Done'));

      final second = h.lastList[1];
      await h.handle(const InboxItem(id: '5', kind: 'message', text: 'snooze 2 monday'));
      expect(store.byId(second)!.due, DateTime(2026, 11, 9));
      expect(said.last, contains('Mon 9 Nov'));
    });

    test('snooze with no date moves the task a day', () async {
      final a = await store.createFromEntry(todayTask('Panamax GST'));
      h.lastList = [a.id];
      await h.handle(const InboxItem(id: '6', kind: 'message', text: 'snooze 1'));
      expect(store.byId(a.id)!.due, DateTime(2026, 11, 6));
    });

    test('a bad number or an empty list is explained, not applied', () async {
      await h.handle(const InboxItem(id: '7', kind: 'message', text: 'done 1'));
      expect(said.last, contains('list'));
      final a = await store.createFromEntry(todayTask('Panamax GST'));
      h.lastList = [a.id];
      await h.handle(const InboxItem(id: '8', kind: 'message', text: 'done 5'));
      expect(said.last, contains('No item 5'));
      expect(store.byId(a.id)!.done, isFalse);
    });

    test('ticking a recurring task rolls it forward', () async {
      final a = await store.createFromEntry(ParsedEntry(
          title: 'GSTR-3B', due: DateTime(2026, 11, 5), isTask: true, repeat: const Repeat('month')));
      h.lastList = [a.id];
      await h.handle(const InboxItem(id: '9', kind: 'message', text: 'done 1'));
      final after = store.byId(a.id)!;
      expect(after.done, isFalse);
      expect(said.last, contains('next'));
    });

    test('help explains the commands', () async {
      await h.handle(const InboxItem(id: '10', kind: 'message', text: 'help'));
      expect(said.last, contains('snooze'));
    });
  });
}
