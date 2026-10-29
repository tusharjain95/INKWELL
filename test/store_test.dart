import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/models.dart';
import 'package:inkwell/core/nlp.dart';
import 'package:inkwell/core/store.dart';

void main() {
  late Directory dir;
  late NoteStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('inkwell_test_');
    store = await NoteStore.open(rootOverride: dir);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  test('notes survive a restart', () async {
    final n = await store.create();
    await store.save(n.copyWith(title: 'Groceries', plain: 'milk, eggs'));
    final reopened = await NoteStore.open(rootOverride: dir);
    expect(reopened.byId(n.id)?.title, 'Groceries');
    expect(reopened.state.dirty, contains(n.id));
  });

  test('search matches title, body and tags; trash is separate', () async {
    final a = await store.create();
    await store.save(a.copyWith(title: 'Invoice', plain: 'pay by friday', tags: ['work']));
    final b = await store.create();
    await store.save(b.copyWith(title: 'Holiday', plain: 'book flights'));
    expect(store.query(search: 'friday').map((n) => n.id), [a.id]);
    expect(store.query(search: 'work').map((n) => n.id), [a.id]);
    expect(store.query(tag: 'work').length, 1);

    await store.softDelete(b.id);
    expect(store.query().map((n) => n.id), [a.id]);
    expect(store.query(trash: true).map((n) => n.id), [b.id]);
    await store.restore(b.id);
    expect(store.query().length, 2);
  });

  test('pinned notes sort first', () async {
    final a = await store.create();
    await store.save(a.copyWith(title: 'old', plain: 'x'));
    final b = await store.create();
    await store.save(b.copyWith(title: 'pinned', plain: 'x', pinned: true,
        updatedAt: DateTime.now().toUtc().subtract(const Duration(days: 3))));
    expect(store.query().first.id, b.id);
  });

  test('a blank, never-synced note is discarded entirely', () async {
    final n = await store.create();
    await store.discardIfBlank(n.id);
    expect(store.byId(n.id), isNull);
    expect(store.state.dirty, isNot(contains(n.id)));
  });

  test('a blank note that is already on the remote becomes a tombstone', () async {
    final n = await store.create();
    store.state.noteShas[n.id] = 'sha';
    await store.discardIfBlank(n.id);
    expect(store.byId(n.id)?.deleted, isTrue);
  });

  test('importing the same file twice stores it once', () async {
    final f = File('${dir.path}/hello.txt')..writeAsStringSync('hello world');
    final a = (await store.importAttachment(f, 'hello.txt')).ref;
    final b = (await store.importAttachment(f, 'copy.txt')).ref;
    expect(a.hash, b.hash);
    expect(a.mime, 'text/plain');
    expect(store.hasBlob(a.hash), isTrue);
    expect(a.size, 11);
  });

  test('empty trash wipes content but keeps tombstones', () async {
    final n = await store.create();
    await store.save(n.copyWith(title: 'secret', plain: 'details'));
    await store.softDelete(n.id);
    await store.emptyTrash();
    final after = store.byId(n.id)!;
    expect(after.deleted, isTrue);
    expect(after.title, isEmpty);
    expect(after.plain, isEmpty);
  });

  test('conflict copies are separate, titled notes', () async {
    final n = await store.create();
    await store.save(n.copyWith(title: 'Plan', plain: 'v1'));
    await store.saveConflictCopy(store.byId(n.id)!);
    final titles = store.query().map((e) => e.title).toList();
    expect(titles, contains('Plan (conflict copy)'));
    expect(store.all.length, 2);
  });

  test('attachment over the size limit is refused', () async {
    final f = File('${dir.path}/big.bin');
    final raf = await f.open(mode: FileMode.write);
    await raf.truncate(kMaxAttachmentBytes + 1);
    await raf.close();
    expect(store.importAttachment(f, 'big.bin'), throwsA(isA<AttachmentTooLarge>()));
  });

  group('tasks', () {
    test('createFromEntry stores task fields', () async {
      final due = DateTime(2030, 1, 5, 15);
      final n = await store.createFromEntry(ParsedEntry(
        title: 'Call Rahul',
        isTask: true,
        due: due,
        hasTime: true,
        priority: 1,
        tags: ['work'],
      ));
      final got = store.byId(n.id)!;
      expect(got.isTask, isTrue);
      expect(got.due, due);
      expect(got.dueHasTime, isTrue);
      expect(got.priority, 1);
      expect(got.tags, ['work']);
    });

    test('views: tasks and today, open tasks sorted by due date', () async {
      final now = DateTime.now();
      final later = DateTime(now.year + 1, 1, 1);
      final t1 = await store.createFromEntry(
          ParsedEntry(title: 'later', isTask: true, due: later));
      final t2 = await store.createFromEntry(ParsedEntry(
          title: 'today', isTask: true, due: DateTime(now.year, now.month, now.day, 23, 59), hasTime: true));
      await store.createFromEntry(ParsedEntry(title: 'a note', body: 'hello'));
      expect(store.query(view: NoteView.tasks).map((n) => n.id), [t2.id, t1.id]);
      expect(store.query(view: NoteView.today).map((n) => n.id), [t2.id]);
      expect(store.openTaskCount, 2);
      await store.toggleDone(t1.id);
      expect(store.openTaskCount, 1);
    });

    test('ticking a recurring task rolls it forward instead of finishing', () async {
      final past = DateTime.now().subtract(const Duration(days: 3));
      final n = await store.createFromEntry(ParsedEntry(
          title: 'water plants', isTask: true, due: past, repeat: const Repeat('day')));
      await store.toggleDone(n.id);
      final got = store.byId(n.id)!;
      expect(got.done, isFalse);
      expect(got.due!.isAfter(DateTime.now()), isTrue);
    });

    test('task fields survive JSON and old notes still load', () {
      final n = Note(
        id: 'a', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026),
        isTask: true, due: DateTime(2030, 2, 3, 4, 5), dueHasTime: true,
        priority: 2, repeat: const Repeat('week', 2),
      );
      final back = Note.fromJson(n.toJson());
      expect(back.due, n.due);
      expect(back.repeat, n.repeat);
      expect(back.priority, 2);
      final plain = Note(id: 'b', createdAt: DateTime.utc(2026), updatedAt: DateTime.utc(2026));
      expect(plain.toJson().containsKey('task'), isFalse);
      expect(Note.fromJson(plain.toJson()).isTask, isFalse);
    });

    test('Repeat.next and addMonths clamp to month end', () {
      expect(const Repeat('month').next(DateTime(2027, 1, 31)), DateTime(2027, 2, 28));
      expect(const Repeat('week', 2).next(DateTime(2027, 1, 1, 9)), DateTime(2027, 1, 15, 9));
      expect(addMonths(DateTime(2028, 1, 31), 1), DateTime(2028, 2, 29));
    });
  });
}
