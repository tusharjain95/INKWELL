import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/digest.dart';
import 'package:inkwell/core/models.dart';

Note task(
  String id,
  String title, {
  DateTime? due,
  bool time = false,
  int prio = 0,
  bool done = false,
  DateTime? updated,
}) =>
    Note(
      id: id,
      title: title,
      isTask: true,
      due: due,
      dueHasTime: time,
      priority: prio,
      done: done,
      createdAt: DateTime.utc(2026, 1, 1),
      updatedAt: (updated ?? DateTime.utc(2026, 1, 1)).toUtc(),
    );

// Thu 5 Nov 2026.
final now8 = DateTime(2026, 11, 5, 8, 30);
const cfgNoWeekly = DigestConfig(weekly: false, nudge: false, escalate: false);

void main() {
  group('QuietHours', () {
    const q = QuietHours(enabled: true, startHour: 22, endHour: 7);

    test('wraps past midnight', () {
      expect(q.contains(DateTime(2026, 1, 1, 23)), isTrue);
      expect(q.contains(DateTime(2026, 1, 1, 3)), isTrue);
      expect(q.contains(DateTime(2026, 1, 1, 7)), isFalse);
      expect(q.contains(DateTime(2026, 1, 1, 12)), isFalse);
      expect(q.contains(DateTime(2026, 1, 1, 22)), isTrue);
    });

    test('shift moves a time to the end of the window', () {
      expect(q.shift(DateTime(2026, 1, 1, 23, 15)), DateTime(2026, 1, 2, 7));
      expect(q.shift(DateTime(2026, 1, 2, 3, 0)), DateTime(2026, 1, 2, 7));
      expect(q.shift(DateTime(2026, 1, 2, 9, 0)), DateTime(2026, 1, 2, 9));
    });

    test('shift handles month end', () {
      expect(q.shift(DateTime(2026, 1, 31, 23)), DateTime(2026, 2, 1, 7));
    });

    test('a same-day window and a disabled one', () {
      const day = QuietHours(enabled: true, startHour: 13, endHour: 15);
      expect(day.contains(DateTime(2026, 1, 1, 14)), isTrue);
      expect(day.shift(DateTime(2026, 1, 1, 14)), DateTime(2026, 1, 1, 15));
      expect(const QuietHours().contains(DateTime(2026, 1, 1, 23)), isFalse);
    });
  });

  group('digest', () {
    final notes = [
      task('a', 'Overdue thing', due: DateTime(2026, 11, 2)),
      task('b', 'Today thing', due: DateTime(2026, 11, 5, 11, 15), time: true, prio: 1),
      task('c', 'Later this week', due: DateTime(2026, 11, 7)),
      task('d', 'Next month', due: DateTime(2026, 12, 20)),
      task('e', 'No date'),
      task('f', 'Finished', due: DateTime(2026, 11, 5), done: true),
    ];

    test('lists overdue, today and coming up with numbers', () {
      final m = buildDigest(now8, notes, cfgNoWeekly)!;
      expect(m.ids, ['a', 'b', 'c']);
      expect(m.text, contains('Overdue (1)'));
      expect(m.text, contains('1. Overdue thing · 3 days late'));
      expect(m.text, contains('Today (1)'));
      expect(m.text, contains('2. ❗ Today thing · 11:15'));
      expect(m.text, contains('3. Later this week · Sat 7 Nov'));
      expect(m.text, isNot(contains('Next month')));
      expect(m.text, isNot(contains('Finished')));
    });

    test('flags stale tasks', () {
      final m = buildDigest(now8, [task('a', 'Old', due: DateTime(2026, 10, 20))], cfgNoWeekly)!;
      expect(m.text, contains('16 days late ⚠️ stale'));
    });

    test('says nothing when there is nothing to do, unless asked', () {
      expect(buildDigest(now8, [task('d', 'x', due: DateTime(2026, 12, 20))], cfgNoWeekly), isNull);
      final m = buildDigest(now8, const [], cfgNoWeekly, always: true)!;
      expect(m.text, contains('Nothing overdue'));
    });

    test('long lists are capped and say how many are left', () {
      final many = [for (var i = 0; i < 30; i++) task('n$i', 'Task $i', due: DateTime(2026, 11, 5))];
      final m = buildDigest(now8, many, cfgNoWeekly)!;
      expect(m.ids.length, 25);
      expect(m.text, contains('+5 more'));
    });
  });

  group('planHubMessages', () {
    final notes = [task('a', 'Call Rahul', due: DateTime(2026, 11, 5), prio: 2)];

    test('sends the digest once a day, at or after its hour', () {
      final early = planHubMessages(
          now: DateTime(2026, 11, 5, 7, 59), notes: notes, cfg: cfgNoWeekly, state: HubState());
      expect(early.messages, isEmpty);

      final first = planHubMessages(now: now8, notes: notes, cfg: cfgNoWeekly, state: HubState());
      expect(first.messages.single.kind, 'digest');

      final again = planHubMessages(
          now: DateTime(2026, 11, 5, 9), notes: notes, cfg: cfgNoWeekly, state: first.state);
      expect(again.messages, isEmpty);

      final tomorrow = planHubMessages(
          now: DateTime(2026, 11, 6, 8, 5),
          notes: [task('a', 'Call Rahul', due: DateTime(2026, 11, 6))],
          cfg: cfgNoWeekly,
          state: first.state);
      expect(tomorrow.messages.single.kind, 'digest');
    });

    test('an empty day is marked as handled without a message', () {
      final r = planHubMessages(now: now8, notes: const [], cfg: cfgNoWeekly, state: HubState());
      expect(r.messages, isEmpty);
      expect(r.state.digestDay, '2026-11-05');
    });

    test('does not send the morning digest late in the evening', () {
      final r = planHubMessages(
          now: DateTime(2026, 11, 5, 20, 30), notes: notes, cfg: cfgNoWeekly, state: HubState());
      expect(r.messages, isEmpty);
    });

    test('quiet hours hold everything, then release it', () {
      const cfg = DigestConfig(
        weekly: false,
        nudge: false,
        escalate: false,
        digestHour: 6,
        quiet: QuietHours(enabled: true, startHour: 22, endHour: 7),
      );
      final quiet = planHubMessages(
          now: DateTime(2026, 11, 5, 6, 30), notes: notes, cfg: cfg, state: HubState());
      expect(quiet.messages, isEmpty);
      expect(quiet.state.digestDay, '', reason: 'must not be marked sent');

      final after = planHubMessages(
          now: DateTime(2026, 11, 5, 7, 5), notes: notes, cfg: cfg, state: quiet.state);
      expect(after.messages.single.kind, 'digest');
    });

    test('the evening nudge lists what is still open today', () {
      const cfg = DigestConfig(digest: false, weekly: false, escalate: false);
      final r = planHubMessages(
          now: DateTime(2026, 11, 5, 17, 5), notes: notes, cfg: cfg, state: HubState());
      expect(r.messages.single.kind, 'nudge');
      expect(r.messages.single.text, contains('Call Rahul'));
      final done = planHubMessages(
          now: DateTime(2026, 11, 5, 17, 5),
          notes: [task('a', 'Call Rahul', due: DateTime(2026, 11, 5), done: true)],
          cfg: cfg,
          state: HubState());
      expect(done.messages, isEmpty);
    });

    test('the weekly review goes out once per week, on its day', () {
      const cfg = DigestConfig(digest: false, nudge: false, escalate: false);
      final sunday = DateTime(2026, 11, 8, 18, 10); // 8 Nov 2026 is a Sunday
      final week = [
        task('d1', 'Filed GSTR-1', done: true, updated: DateTime(2026, 11, 4, 10)),
        task('o1', 'Slipped one', due: DateTime(2026, 11, 3)),
        task('n1', 'Next week', due: DateTime(2026, 11, 10)),
      ];
      final r = planHubMessages(now: sunday, notes: week, cfg: cfg, state: HubState());
      final m = r.messages.single;
      expect(m.kind, 'weekly');
      expect(m.text, contains('Done this week: 1'));
      expect(m.text, contains('Filed GSTR-1'));
      expect(m.text, contains('Slipped one'));
      expect(m.text, contains('Next week'));
      expect(m.ids, ['o1', 'n1']);

      final again = planHubMessages(
          now: DateTime(2026, 11, 8, 19), notes: week, cfg: cfg, state: r.state);
      expect(again.messages, isEmpty);

      final wrongDay = planHubMessages(
          now: DateTime(2026, 11, 6, 18, 10), notes: week, cfg: cfg, state: HubState());
      expect(wrongDay.messages, isEmpty);

      // Held by quiet hours on Sunday evening, sent first thing Monday.
      const quiet = DigestConfig(
        digest: false,
        nudge: false,
        escalate: false,
        weeklyHour: 23,
        quiet: QuietHours(enabled: true, startHour: 22, endHour: 7),
      );
      final held = planHubMessages(
          now: DateTime(2026, 11, 8, 23, 30), notes: week, cfg: quiet, state: HubState());
      expect(held.messages, isEmpty);
      final monday = planHubMessages(
          now: DateTime(2026, 11, 9, 7, 10), notes: week, cfg: quiet, state: held.state);
      expect(monday.messages.single.kind, 'weekly');
    });
  });

  group('escalation', () {
    const cfg = DigestConfig(digest: false, nudge: false, weekly: false);
    final due = DateTime(2026, 11, 5, 10, 0);
    final urgent = [task('u', 'File TDS return', due: due, time: true, prio: 1)];
    final normal = [task('n', 'Call vendor', due: due, time: true, prio: 2)];

    test('waits an hour after the due time', () {
      final r = planHubMessages(
          now: DateTime(2026, 11, 5, 10, 59), notes: urgent, cfg: cfg, state: HubState());
      expect(r.messages, isEmpty);
    });

    test('climbs one level at a time and never repeats a level', () {
      var state = HubState();
      var r = planHubMessages(now: DateTime(2026, 11, 5, 11, 5), notes: urgent, cfg: cfg, state: state);
      expect(r.messages.single.kind, 'escalation');
      expect(r.messages.single.text, contains('1h late'));
      expect(r.messages.single.ids, ['u']);
      state = r.state;

      r = planHubMessages(now: DateTime(2026, 11, 5, 15), notes: urgent, cfg: cfg, state: state);
      expect(r.messages, isEmpty);

      r = planHubMessages(now: DateTime(2026, 11, 6, 10, 30), notes: urgent, cfg: cfg, state: state);
      expect(r.messages.single.text, contains('1 day late'));
      state = r.state;

      r = planHubMessages(now: DateTime(2026, 11, 8, 12), notes: urgent, cfg: cfg, state: state);
      expect(r.messages.single.text, contains('stale'));
      state = r.state;

      r = planHubMessages(now: DateTime(2026, 11, 9, 12), notes: urgent, cfg: cfg, state: state);
      expect(r.messages, isEmpty);
    });

    test('only high-priority tasks escalate', () {
      final r = planHubMessages(now: DateTime(2026, 11, 7, 12), notes: normal, cfg: cfg, state: HubState());
      expect(r.messages, isEmpty);
    });

    test('a snoozed task starts over', () {
      var r = planHubMessages(now: DateTime(2026, 11, 5, 11, 5), notes: urgent, cfg: cfg, state: HubState());
      final moved = [task('u', 'File TDS return', due: DateTime(2026, 11, 6, 10), time: true, prio: 1)];
      r = planHubMessages(now: DateTime(2026, 11, 6, 11, 5), notes: moved, cfg: cfg, state: r.state);
      expect(r.messages.single.text, contains('1h late'));
    });

    test('catching up after quiet hours sends one message at the highest level', () {
      const quietCfg = DigestConfig(
        digest: false,
        nudge: false,
        weekly: false,
        quiet: QuietHours(enabled: true, startHour: 22, endHour: 7),
      );
      final held = planHubMessages(
          now: DateTime(2026, 11, 6, 3), notes: urgent, cfg: quietCfg, state: HubState());
      expect(held.messages, isEmpty);
      final out = planHubMessages(
          now: DateTime(2026, 11, 6, 7, 5), notes: urgent, cfg: quietCfg, state: held.state);
      expect(out.messages.single.text, contains('late'));
      expect(out.messages.length, 1);
    });

    test('is not repeated for a task the digest just listed', () {
      const both = DigestConfig(nudge: false, weekly: false);
      final r = planHubMessages(
        now: DateTime(2026, 11, 6, 9),
        notes: [task('u', 'File TDS return', due: DateTime(2026, 11, 5), prio: 1)],
        cfg: both,
        state: HubState(),
      );
      expect(r.messages.map((m) => m.kind), ['digest']);
    });
  });

  test('state survives JSON and ignores garbage', () {
    final s = HubState(digestDay: '2026-11-05', esc: {'a': [2, 99]}, lastList: ['a', 'b']);
    final back = HubState.fromJson(s.toJson());
    expect(back.digestDay, '2026-11-05');
    expect(back.esc['a'], [2, 99]);
    expect(back.lastList, ['a', 'b']);
    expect(HubState.fromJson('not json').lastList, isEmpty);
    expect(HubState.fromJson(null).digestDay, '');
  });
}
