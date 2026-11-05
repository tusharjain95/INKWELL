import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/models.dart';
import 'package:inkwell/core/widget_sync.dart';

Note n(
  String id, {
  String title = 'x',
  bool task = false,
  bool done = false,
  DateTime? due,
  int prio = 0,
  bool pinned = false,
  bool deleted = false,
  int updated = 1,
}) =>
    Note(
      id: id,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: DateTime.utc(2026, 1, updated),
      title: title,
      plain: 'body of $id',
      isTask: task,
      done: done,
      due: due,
      priority: prio,
      pinned: pinned,
      deleted: deleted,
    );

List<String> ids(String json) =>
    [for (final i in (jsonDecode(json)['items'] as List)) i['id'] as String];

void main() {
  final now = DateTime(2026, 5, 10, 12);

  test('tasks: open only, due first, then priority, undated last', () {
    final p = buildWidgetPayload([
      n('undated', task: true),
      n('later', task: true, due: DateTime(2026, 5, 20)),
      n('soon', task: true, due: DateTime(2026, 5, 11)),
      n('overdue', task: true, due: DateTime(2026, 5, 1)),
      n('done', task: true, done: true, due: DateTime(2026, 5, 1)),
      n('gone', task: true, deleted: true),
      n('note'),
    ], now);
    expect(ids(p[kWidgetTasksKey]!), ['overdue', 'soon', 'later', 'undated']);
    expect(jsonDecode(p[kWidgetTasksKey]!)['count'], 4);
  });

  test('same due day sorts by priority, none last', () {
    final d = DateTime(2026, 5, 11);
    final p = buildWidgetPayload([
      n('none', task: true, due: d),
      n('low', task: true, due: d, prio: 3),
      n('high', task: true, due: d, prio: 1),
    ], now);
    expect(ids(p[kWidgetTasksKey]!), ['high', 'low', 'none']);
  });

  test('labels and overdue flag', () {
    final p = buildWidgetPayload([
      n('a', task: true, due: DateTime(2026, 5, 10)),
      n('b', task: true, due: DateTime(2026, 5, 11, 9, 5)),
      n('c', task: true, due: DateTime(2026, 5, 2)),
    ], now);
    final items = jsonDecode(p[kWidgetTasksKey]!)['items'] as List;
    final byId = {for (final i in items) i['id']: i};
    expect(byId['a']['sub'], 'Today');
    expect(byId['c']['sub'], '2 May');
    expect(byId['c']['overdue'], isTrue);
  });

  test('notes: pinned first then newest; tasks excluded; title fallback', () {
    final p = buildWidgetPayload([
      n('old', updated: 1),
      n('new', updated: 5),
      n('pin', updated: 2, pinned: true),
      n('untitled', title: '', updated: 3),
      n('t', task: true),
    ], now);
    expect(ids(p[kWidgetNotesKey]!), ['pin', 'new', 'untitled', 'old']);
    final items = jsonDecode(p[kWidgetNotesKey]!)['items'] as List;
    expect(items.firstWhere((i) => i['id'] == 'untitled')['title'], 'body of untitled');
  });

  test('payload is capped', () {
    final many = [for (var i = 0; i < 100; i++) n('t$i', task: true)];
    final p = buildWidgetPayload(many, now);
    expect(ids(p[kWidgetTasksKey]!).length, kWidgetMaxItems);
    expect(jsonDecode(p[kWidgetTasksKey]!)['count'], 100);
  });
}
