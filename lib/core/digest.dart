import 'dart:convert';

import 'models.dart';

/// Pure planning logic for the Telegram messages Inkwell sends: the morning
/// digest, the evening nudge, the weekly review and escalation of overdue
/// high-priority tasks. Nothing here touches the network, the clock or the
/// disk, so it is easy to test; the hub service feeds it and sends the result.

const List<String> _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const List<String> _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

String _p2(int v) => v.toString().padLeft(2, '0');

String dayKey(DateTime d) => '${d.year}-${_p2(d.month)}-${_p2(d.day)}';
DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
DateTime _atHour(DateTime day, int hour) => DateTime(day.year, day.month, day.day, hour);

int daysBetween(DateTime a, DateTime b) => DateTime.utc(b.year, b.month, b.day)
    .difference(DateTime.utc(a.year, a.month, a.day))
    .inDays;

String fmtDay(DateTime d) => '${_weekdayNames[d.weekday - 1]} ${d.day} ${_monthNames[d.month - 1]}';
String fmtClock(DateTime d) => '${_p2(d.hour)}:${_p2(d.minute)}';

/// "Thu 5 Nov" or "Thu 5 Nov 17:00".
String fmtDue(DateTime d, bool hasTime) => hasTime ? '${fmtDay(d)} ${fmtClock(d)}' : fmtDay(d);

/// A window each day when Inkwell stays quiet (for example 22:00 to 07:00).
class QuietHours {
  const QuietHours({this.enabled = false, this.startHour = 22, this.endHour = 7});

  final bool enabled;
  final int startHour;
  final int endHour;

  bool contains(DateTime t) {
    if (!enabled || startHour == endHour) return false;
    final h = t.hour;
    return startHour < endHour ? (h >= startHour && h < endHour) : (h >= startHour || h < endHour);
  }

  /// [t] itself, or the moment quiet hours end if [t] falls inside them.
  DateTime shift(DateTime t) {
    if (!contains(t)) return t;
    var end = DateTime(t.year, t.month, t.day, endHour);
    if (!end.isAfter(t)) end = DateTime(t.year, t.month, t.day + 1, endHour);
    return end;
  }
}

class DigestConfig {
  const DigestConfig({
    this.digest = true,
    this.digestHour = 8,
    this.nudge = true,
    this.nudgeHour = 17,
    this.weekly = true,
    this.weeklyDay = DateTime.sunday,
    this.weeklyHour = 18,
    this.escalate = true,
    this.quiet = const QuietHours(),
    this.dayStartHour = 9,
    this.staleDays = 7,
  });

  final bool digest;
  final int digestHour;
  final bool nudge;
  final int nudgeHour;
  final bool weekly;

  /// DateTime.monday .. DateTime.sunday.
  final int weeklyDay;
  final int weeklyHour;
  final bool escalate;
  final QuietHours quiet;

  /// The hour a task with only a date is treated as due.
  final int dayStartHour;

  /// Days overdue before a task is called stale.
  final int staleDays;
}

/// What has already been sent, so each message goes out once.
class HubState {
  HubState({
    this.digestDay = '',
    this.nudgeDay = '',
    this.weeklyDay = '',
    Map<String, List<int>>? esc,
    List<String>? lastList,
  })  : esc = esc ?? {},
        lastList = lastList ?? [];

  String digestDay;
  String nudgeDay;
  String weeklyDay;

  /// note id -> [level reached, due time in ms when it was reached].
  Map<String, List<int>> esc;

  /// The note ids behind the numbers in the latest numbered message, so a
  /// reply like "done 3" knows which task is meant.
  List<String> lastList;

  HubState copy() => HubState(
        digestDay: digestDay,
        nudgeDay: nudgeDay,
        weeklyDay: weeklyDay,
        esc: {for (final e in esc.entries) e.key: List<int>.from(e.value)},
        lastList: List<String>.from(lastList),
      );

  String toJson() => jsonEncode({
        'digest': digestDay,
        'nudge': nudgeDay,
        'weekly': weeklyDay,
        'esc': esc,
        'list': lastList,
      });

  factory HubState.fromJson(String? raw) {
    if (raw == null || raw.isEmpty) return HubState();
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final esc = <String, List<int>>{};
      (j['esc'] as Map? ?? const {}).forEach((k, v) {
        esc['$k'] = (v as List).map((e) => (e as num).toInt()).toList();
      });
      return HubState(
        digestDay: (j['digest'] as String?) ?? '',
        nudgeDay: (j['nudge'] as String?) ?? '',
        weeklyDay: (j['weekly'] as String?) ?? '',
        esc: esc,
        lastList: ((j['list'] as List?) ?? const []).map((e) => '$e').toList(),
      );
    } catch (_) {
      return HubState();
    }
  }
}

class PlannedMessage {
  const PlannedMessage(this.kind, this.text, [this.ids = const []]);

  /// digest, nudge, weekly, escalation or list.
  final String kind;
  final String text;

  /// The notes behind the numbers in [text], in order.
  final List<String> ids;
}

class PlanResult {
  const PlanResult(this.messages, this.state);
  final List<PlannedMessage> messages;
  final HubState state;
}

bool _open(Note n) => !n.deleted && n.isTask && !n.done;

String _title(Note n) => n.title.trim().isEmpty ? 'Untitled' : n.title.trim();

DateTime? _dueAt(Note n, int dayStartHour) {
  final d = n.due;
  if (d == null) return null;
  return n.dueHasTime ? d : _atHour(dayOf(d), dayStartHour);
}

String _late(Duration d) {
  if (d.inHours < 24) return '${d.inHours < 1 ? 1 : d.inHours}h late';
  final days = d.inDays;
  return days == 1 ? '1 day late' : '$days days late';
}

int _cmp(Note a, Note b, int dayStart) {
  final c = _dueAt(a, dayStart)!.compareTo(_dueAt(b, dayStart)!);
  if (c != 0) return c;
  int rank(int p) => p == 0 ? 4 : p;
  return rank(a.priority).compareTo(rank(b.priority));
}

const int _maxLines = 25;

/// Numbered lines for [sections]; returns the text and the ids in order.
(String, List<String>) _numbered(
  List<(String, List<Note>, String Function(Note))> sections,
) {
  final b = StringBuffer();
  final ids = <String>[];
  var more = 0;
  for (final (heading, notes, suffix) in sections) {
    if (notes.isEmpty) continue;
    if (b.isNotEmpty) b.writeln();
    b.writeln('$heading (${notes.length})');
    for (final n in notes) {
      if (ids.length >= _maxLines) {
        more++;
        continue;
      }
      ids.add(n.id);
      final star = n.priority == 1 ? '❗ ' : '';
      b.writeln('${ids.length}. $star${_title(n)}${suffix(n)}');
    }
  }
  if (more > 0) {
    b.writeln();
    b.writeln('+$more more in Inkwell');
  }
  return (b.toString().trimRight(), ids);
}

const String _replyHint = 'Reply "done 2" or "snooze 2 tomorrow".';

/// The morning list: overdue, due today, and the next three days.
/// Returns null when nothing is overdue or due today (unless [always]).
PlannedMessage? buildDigest(
  DateTime now,
  List<Note> notes,
  DigestConfig cfg, {
  bool always = false,
}) {
  final today = dayOf(now);
  final over = <Note>[], due = <Note>[], soon = <Note>[];
  for (final n in notes.where(_open)) {
    final d = n.due;
    if (d == null) continue;
    final days = daysBetween(today, d);
    if (days < 0) {
      over.add(n);
    } else if (days == 0) {
      due.add(n);
    } else if (days <= 3) {
      soon.add(n);
    }
  }
  if (over.isEmpty && due.isEmpty) {
    return always ? const PlannedMessage('list', 'Nothing overdue or due today. 🎉') : null;
  }
  for (final l in [over, due, soon]) {
    l.sort((a, b) => _cmp(a, b, cfg.dayStartHour));
  }
  final (body, ids) = _numbered([
    (
      'Overdue',
      over,
      (Note n) {
        final days = daysBetween(n.due!, today);
        final stale = days >= cfg.staleDays ? ' ⚠️ stale' : '';
        return ' · ${days == 1 ? '1 day' : '$days days'} late$stale';
      }
    ),
    ('Today', due, (Note n) => n.dueHasTime ? ' · ${fmtClock(n.due!)}' : ''),
    ('Coming up', soon, (Note n) => ' · ${fmtDue(n.due!, n.dueHasTime)}'),
  ]);
  return PlannedMessage(
    always ? 'list' : 'digest',
    '☀️ ${fmtDay(now)}\n\n$body\n\n$_replyHint',
    ids,
  );
}

PlannedMessage? _buildNudge(DateTime now, List<Note> notes, DigestConfig cfg) {
  final today = dayOf(now);
  final todays = <Note>[], urgent = <Note>[];
  for (final n in notes.where(_open)) {
    final d = n.due;
    if (d == null) continue;
    final days = daysBetween(today, d);
    if (days == 0) {
      todays.add(n);
    } else if (days < 0 && n.priority == 1) {
      urgent.add(n);
    }
  }
  if (todays.isEmpty && urgent.isEmpty) return null;
  todays.sort((a, b) => _cmp(a, b, cfg.dayStartHour));
  urgent.sort((a, b) => _cmp(a, b, cfg.dayStartHour));
  final (body, ids) = _numbered([
    ('Still open today', todays, (Note n) => n.dueHasTime ? ' · ${fmtClock(n.due!)}' : ''),
    ('Overdue and urgent', urgent, (Note n) => ' · ${_late(now.difference(_dueAt(n, cfg.dayStartHour)!))}'),
  ]);
  return PlannedMessage('nudge', '🔔 Before the day ends\n\n$body\n\n$_replyHint', ids);
}

PlannedMessage? _buildWeekly(DateTime now, List<Note> notes, DigestConfig cfg) {
  final today = dayOf(now);
  final weekAgo = now.subtract(const Duration(days: 7));
  final finished = notes
      .where((Note n) =>
          !n.deleted && n.isTask && n.done && n.updatedAt.toLocal().isAfter(weekAgo))
      .toList();
  final over = <Note>[], next = <Note>[];
  for (final n in notes.where(_open)) {
    final d = n.due;
    if (d == null) continue;
    final days = daysBetween(today, d);
    if (days < 0) {
      over.add(n);
    } else if (days <= 7) {
      next.add(n);
    }
  }
  if (finished.isEmpty && over.isEmpty && next.isEmpty) return null;
  over.sort((a, b) => _cmp(a, b, cfg.dayStartHour));
  next.sort((a, b) => _cmp(a, b, cfg.dayStartHour));

  final b = StringBuffer('📊 Week in review\n');
  b.writeln();
  b.writeln('✅ Done this week: ${finished.length}');
  for (final n in finished.take(8)) {
    b.writeln('  • ${_title(n)}');
  }
  if (finished.length > 8) b.writeln('  …and ${finished.length - 8} more');

  final (body, ids) = _numbered([
    ('⚠️ Slipped', over, (Note n) => ' · ${daysBetween(n.due!, today)}d late'),
    ('📅 Next 7 days', next, (Note n) => ' · ${fmtDue(n.due!, n.dueHasTime)}'),
  ]);
  if (body.isNotEmpty) {
    b.writeln();
    b.writeln(body);
    b.writeln();
    b.write(_replyHint);
  }
  return PlannedMessage('weekly', b.toString().trimRight(), ids);
}

/// Decides which messages are due right now.
///
/// * Inside quiet hours nothing is sent and nothing is marked as sent, so
///   what is waiting goes out when quiet hours end.
/// * Each digest, nudge and weekly review is sent once per day or week, at or
///   after its hour.
/// * Escalation covers high-priority tasks only: a nudge one hour after the
///   due time, again after a day, and a final stale warning after three.
///   Only the highest level reached is sent, in a single message.
PlanResult planHubMessages({
  required DateTime now,
  required List<Note> notes,
  required DigestConfig cfg,
  required HubState state,
}) {
  final st = state.copy();
  final out = <PlannedMessage>[];
  if (cfg.quiet.contains(now)) return PlanResult(out, st);

  final today = dayOf(now);
  final shown = <String>{};

  if (cfg.digest &&
      st.digestDay != dayKey(now) &&
      !now.isBefore(_atHour(today, cfg.digestHour)) &&
      now.hour < 20) {
    st.digestDay = dayKey(now);
    final m = buildDigest(now, notes, cfg);
    if (m != null) {
      out.add(m);
      shown.addAll(m.ids);
    }
  }

  if (cfg.nudge &&
      st.nudgeDay != dayKey(now) &&
      !now.isBefore(_atHour(today, cfg.nudgeHour)) &&
      now.hour < 22) {
    st.nudgeDay = dayKey(now);
    final m = _buildNudge(now, notes, cfg);
    if (m != null) {
      out.add(m);
      shown.addAll(m.ids);
    }
  }

  if (cfg.weekly) {
    final back = (now.weekday - cfg.weeklyDay + 7) % 7;
    final targetDay = DateTime(today.year, today.month, today.day - back);
    final target = _atHour(targetDay, cfg.weeklyHour);
    if (!now.isBefore(target) &&
        now.difference(target) < const Duration(hours: 36) &&
        st.weeklyDay != dayKey(targetDay)) {
      st.weeklyDay = dayKey(targetDay);
      final m = _buildWeekly(now, notes, cfg);
      if (m != null) {
        out.add(m);
        shown.addAll(m.ids);
      }
    }
  }

  if (cfg.escalate) {
    final lines = <Note>[];
    final suffix = <String, String>{};
    final live = <String>{};
    for (final n in notes.where(_open)) {
      if (n.priority != 1) continue;
      final at = _dueAt(n, cfg.dayStartHour);
      if (at == null) continue;
      live.add(n.id);
      final late = now.difference(at);
      final level = late >= const Duration(days: 3)
          ? 3
          : late >= const Duration(days: 1)
              ? 2
              : late >= const Duration(hours: 1)
                  ? 1
                  : 0;
      if (level == 0) continue;
      final seen = st.esc[n.id];
      if (seen != null && seen[1] == at.millisecondsSinceEpoch && seen[0] >= level) {
        continue; // this level (or a higher one) was already sent for this due time
      }
      st.esc[n.id] = [level, at.millisecondsSinceEpoch];
      if (shown.contains(n.id)) continue; // just listed above
      lines.add(n);
      suffix[n.id] = ' · ${_late(late)}${level == 3 ? ' ⚠️ stale' : ''}';
    }
    st.esc.removeWhere((id, _) => !live.contains(id));
    if (lines.isNotEmpty) {
      lines.sort((a, b) => _cmp(a, b, cfg.dayStartHour));
      final (body, ids) = _numbered([('Needs attention', lines, (Note n) => suffix[n.id] ?? '')]);
      out.add(PlannedMessage('escalation', '⏰ High priority and overdue\n\n$body\n\n$_replyHint', ids));
    }
  }

  return PlanResult(out, st);
}
