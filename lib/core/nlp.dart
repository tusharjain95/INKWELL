// Natural-language entry parser: turns "call Rahul friday 3:30pm !1 #work"
// into a task with a due date, priority and tags.
//
// Everything runs locally with plain pattern matching; nothing leaves the
// device and no model download is needed. It understands English phrases.
//
// This is a line-for-line port of a Python reference implementation whose
// 39 table-driven cases are reproduced in test/nlp_test.dart.
import 'models.dart';

class ParsedEntry {
  ParsedEntry({
    this.title = '',
    this.body = '',
    this.due,
    this.hasTime = false,
    this.priority = 0,
    List<String>? tags,
    this.repeat,
    this.isTask = false,
  }) : tags = tags ?? [];

  String title;

  /// Longer text for notes. Empty for tasks.
  String body;
  DateTime? due;
  bool hasTime;

  /// 0 none, 1 high, 2 medium, 3 low.
  int priority;
  List<String> tags;
  Repeat? repeat;
  bool isTask;

  bool get isEmpty => title.isEmpty && body.isEmpty;
}

const Map<String, int> _weekdays = {
  'monday': 1, 'tuesday': 2, 'wednesday': 3, 'thursday': 4,
  'friday': 5, 'saturday': 6, 'sunday': 7,
};
const Map<String, int> _weekdayAbbr = {
  'mon': 1, 'tue': 2, 'tues': 2, 'wed': 3, 'thu': 4, 'thur': 4,
  'thurs': 4, 'fri': 5, 'sat': 6, 'sun': 7,
};
const Map<String, int> _months = {
  'january': 1, 'jan': 1, 'february': 2, 'feb': 2, 'march': 3, 'mar': 3,
  'april': 4, 'apr': 4, 'may': 5, 'june': 6, 'jun': 6, 'july': 7, 'jul': 7,
  'august': 8, 'aug': 8, 'september': 9, 'sep': 9, 'sept': 9,
  'october': 10, 'oct': 10, 'november': 11, 'nov': 11,
  'december': 12, 'dec': 12,
};
const Map<String, int> _numWords = {
  'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
  'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'twelve': 12,
};
const Set<String> _taskVerbs = {
  'call', 'buy', 'email', 'text', 'message', 'send', 'pay', 'book',
  'schedule', 'submit', 'finish', 'complete', 'renew', 'order', 'pick',
  'drop', 'clean', 'fix', 'update', 'review', 'prepare', 'plan', 'file',
  'follow', 'check', 'ask', 'cancel', 'collect', 'deliver', 'print',
  'sign', 'return', 'register', 'apply', 'visit', 'meet', 'organise',
  'organize', 'arrange', 'confirm', 'remind', 'water', 'wash', 'cook',
};

String _byLength(Iterable<String> keys) =>
    (keys.toList()..sort((a, b) => b.length.compareTo(a.length))).join('|');

final String _wdFull = _weekdays.keys.join('|');
final String _wdAbbr = _byLength(_weekdayAbbr.keys);
final String _monthAlt = _byLength(_months.keys);

RegExp _re(String p) => RegExp(p, caseSensitive: false);

final RegExp _reTaskPrefix = _re(
    r"^\s*(?:remind me(?: to| that| about)?|reminder:?|don'?t forget to|"
    r'to-?do:?|task:?|add (?:a )?task(?: to)?:?|i need to|i have to|i must)\s+');
final RegExp _reNotePrefix = _re(
    r'^\s*(?:note(?: to self)?\s*:|note to self\s+|note that\s+|jot down\s+|write down\s+)');

final RegExp _reEveryN = _re(r'\bevery\s+(\d+)\s*(day|week|month|year)s?\b');
final RegExp _reEveryOther = _re(r'\bevery\s+other\s+(day|week|month|year)\b');
final RegExp _reEveryUnit = _re(r'\bevery\s+(day|week|month|year)\b');
final RegExp _reEveryWd = _re(r'\bevery\s+(' + _wdFull + r')s?\b');
final RegExp _reAdverb = _re(r'\b(daily|weekly|monthly|yearly|annually)\b');

final RegExp _rePrioBang = RegExp(r'(?<![\w])!([123])(?!\d)');
final RegExp _rePrioHigh =
    _re(r'\b(?:urgent|asap|high priority|top priority)\b:?');
final RegExp _rePrioMed = _re(r'\bmedium priority\b');
final RegExp _rePrioLow = _re(r'\blow priority\b');
final RegExp _reTag = RegExp(r'(?<![\w&])#([A-Za-z][\w-]*)');

final RegExp _reIso = _re(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b');
final RegExp _reDmyName = _re(
    r'\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(' + _monthAlt + r')\b(?:,?\s+(\d{4})\b)?');
final RegExp _reMdyName = _re(
    r'\b(' + _monthAlt + r')\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4})\b)?');
final RegExp _reNumDate = _re(r'\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b');
final RegExp _reInN = _re(
    r'\bin\s+(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|twelve)\s+'
    r'(minute|min|hour|hr|day|week|month|year)s?\b');
final RegExp _reInHalfHour = _re(r'\bin\s+half\s+an?\s+hour\b');
final RegExp _reDayAfter = _re(r'\bday after tomorrow\b');
final RegExp _reRelDay = _re(r'\b(today|tonight|tomorrow|tmrw|tmr)\b');
final RegExp _reWdFull = _re(r'\b(?:(next|this|coming)\s+)?(' + _wdFull + r')\b');
final RegExp _reWdAbbr = _re(r'\b(on|by|before|until|next|this)\s+(' + _wdAbbr + r')\b');
final RegExp _reNextWeek = _re(r'\bnext week\b');
final RegExp _reNextMonth = _re(r'\bnext month\b');
final RegExp _reWeekend = _re(r'\b(?:this\s+)?weekend\b');
final RegExp _reEndMonth = _re(r'\bend of (?:the )?month\b');

final RegExp _reTimeAmPm =
    _re(r'\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)(?!\w)');
final RegExp _reTime24 = _re(r'\b(?:at\s+)?([01]?\d|2[0-3]):([0-5]\d)\b');
final RegExp _reTimeAt = _re(r'\bat\s+(\d{1,2})\b(?!\s*[/:\-.\d])');
final RegExp _reNoon = _re(r'\bnoon\b');
final RegExp _reMidnight = _re(r'\bmidnight\b');
final RegExp _rePartOfDay =
    _re(r'\b(?:(?:in\s+the|this)\s+)?(morning|afternoon|evening)\b');
final RegExp _rePartOfDayStrict =
    _re(r'\b(?:in\s+the|this)\s+(morning|afternoon|evening)\b');

final RegExp _reDanglingStart =
    _re(r'^(?:(?:on|at|by|before|until|due|for|in|from|to)\b[\s,]*)+');
final RegExp _reDanglingEnd =
    _re(r'(?:[\s,]*\b(?:on|at|by|before|until|due|for|in|from|to|every|next|this))+$');
final RegExp _reEdgePunct = RegExp(r'^[\s,.;:\-–]+|[\s,;:\-–]+$');
final RegExp _reWs = RegExp(r'\s+');

String _cut(String s, Match m) => '${s.substring(0, m.start)} ${s.substring(m.end)}';

DateTime _addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

DateTime _upcoming(DateTime today, int wd, bool includeToday) {
  var delta = (wd - today.weekday) % 7;
  if (delta == 0 && !includeToday) delta = 7;
  return _addDays(today, delta);
}

int _hour24(int h, String mer) {
  final m = mer.toLowerCase().replaceAll('.', '');
  return m == 'am' ? h % 12 : h % 12 + 12;
}

String _capitalise(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

String _cleanTitle(String input) {
  var s = input.replaceAll(_reWs, ' ').trim();
  String? prev;
  while (prev != s) {
    prev = s;
    s = s.replaceFirst(_reDanglingStart, '').trim();
    s = s.replaceFirst(_reDanglingEnd, '').trim();
    s = s.replaceAll(_reEdgePunct, '');
  }
  return _capitalise(s.trim());
}

DateTime? _resolveMonthDay(DateTime today, int mon, int day, String? yearStr) {
  DateTime? valid(int y) {
    final d = DateTime(y, mon, day);
    return (d.month == mon && d.day == day) ? d : null;
  }

  if (yearStr != null) {
    var y = int.parse(yearStr);
    if (y < 100) y += 2000;
    return valid(y);
  }
  final d = valid(today.year);
  if (d == null) return null;
  return d.isBefore(today) ? valid(today.year + 1) : d;
}

DateTime _weekdayDate(DateTime today, int wd, String modifier) {
  if (modifier == 'next') {
    final start = _addDays(today, 8 - today.weekday);
    return _addDays(start, wd - 1);
  }
  if (modifier == 'this' || modifier == 'coming') {
    return _upcoming(today, wd, true);
  }
  return _upcoming(today, wd, false);
}

(String, String) _noteTitleBody(String input) {
  final text = input.trim();
  if (text.isEmpty) return ('', '');
  final nl = text.indexOf('\n');
  final firstLine = (nl < 0 ? text : text.substring(0, nl)).trim();
  if (firstLine.length <= 60 && (nl >= 0 || text.length <= 60)) {
    final body = nl >= 0 ? text.substring(firstLine.length).trim() : '';
    var title = firstLine;
    while (title.endsWith('.')) {
      title = title.substring(0, title.length - 1);
    }
    return (_capitalise(title), body);
  }
  var cut = firstLine.length > 60 ? firstLine.substring(0, 60) : firstLine;
  final sp = cut.lastIndexOf(' ');
  if (sp > 0) cut = cut.substring(0, sp);
  cut = cut.replaceAll(RegExp(r'^[ ,;:\-]+|[ ,;:\-]+$'), '');
  return ('${_capitalise(cut)}…', text);
}

/// Parses free text typed or dictated by the user.
///
/// [now] is injectable for tests. [dayFirst] controls how 12/11 is read
/// (12 November when true, December 11 when false).
ParsedEntry parseEntry(String text, {DateTime? now, bool dayFirst = true}) {
  final nowT = now ?? DateTime.now();
  final today = DateTime(nowT.year, nowT.month, nowT.day);
  final trimmed = text.trim();
  var s = trimmed.contains('\n') ? trimmed : trimmed.replaceAll(_reWs, ' ');
  var original = s;
  final out = ParsedEntry();

  var explicitTask = false;
  var forceNote = false;
  var m = _reTaskPrefix.firstMatch(s);
  if (m != null) {
    explicitTask = true;
    s = s.substring(m.end);
  } else {
    m = _reNotePrefix.firstMatch(s);
    if (m != null) {
      forceNote = true;
      s = s.substring(m.end).trim();
      original = s;
    }
  }

  // Tags work for notes and tasks alike.
  for (final t in _reTag.allMatches(s)) {
    final tag = t.group(1)!.toLowerCase();
    if (!out.tags.contains(tag)) out.tags.add(tag);
  }
  s = s.replaceAll(_reTag, ' ');

  if (forceNote) {
    final body =
        original.replaceAll(_reTag, '').trim().replaceAll(RegExp(r'[ \t]+'), ' ');
    final tb = _noteTitleBody(body);
    out.title = tb.$1;
    out.body = tb.$2;
    return out;
  }

  // ---- priority --------------------------------------------------------
  m = _rePrioBang.firstMatch(s);
  if (m != null) {
    out.priority = int.parse(m.group(1)!);
    s = _cut(s, m);
  }
  for (final (rx, pr) in [(_rePrioHigh, 1), (_rePrioMed, 2), (_rePrioLow, 3)]) {
    m = rx.firstMatch(s);
    if (m != null) {
      if (out.priority == 0) out.priority = pr;
      s = _cut(s, m);
    }
  }

  // ---- recurrence --------------------------------------------------------
  int? anchorWd;
  m = _reEveryN.firstMatch(s);
  if (m != null) {
    final n = int.parse(m.group(1)!);
    out.repeat = Repeat(m.group(2)!.toLowerCase(), n < 1 ? 1 : n);
    s = _cut(s, m);
  }
  if (out.repeat == null) {
    m = _reEveryOther.firstMatch(s);
    if (m != null) {
      out.repeat = Repeat(m.group(1)!.toLowerCase(), 2);
      s = _cut(s, m);
    }
  }
  if (out.repeat == null) {
    m = _reEveryWd.firstMatch(s);
    if (m != null) {
      out.repeat = const Repeat('week', 1);
      anchorWd = _weekdays[m.group(1)!.toLowerCase()];
      s = _cut(s, m);
    }
  }
  if (out.repeat == null) {
    m = _reEveryUnit.firstMatch(s);
    if (m != null) {
      out.repeat = Repeat(m.group(1)!.toLowerCase(), 1);
      s = _cut(s, m);
    }
  }
  if (out.repeat == null) {
    m = _reAdverb.firstMatch(s);
    if (m != null) {
      const units = {
        'daily': 'day', 'weekly': 'week', 'monthly': 'month',
        'yearly': 'year', 'annually': 'year',
      };
      out.repeat = Repeat(units[m.group(1)!.toLowerCase()]!, 1);
      s = _cut(s, m);
    }
  }

  // ---- date ----------------------------------------------------------------
  DateTime? date;
  int? minutesOffset;

  m = _reIso.firstMatch(s);
  if (m != null) {
    final y = int.parse(m.group(1)!);
    final mo = int.parse(m.group(2)!);
    final d = int.parse(m.group(3)!);
    final cand = DateTime(y, mo, d);
    if (cand.month == mo && cand.day == d) {
      date = cand;
      s = _cut(s, m);
    }
  }
  if (date == null) {
    m = _reDmyName.firstMatch(s);
    if (m != null) {
      date = _resolveMonthDay(today, _months[m.group(2)!.toLowerCase()]!,
          int.parse(m.group(1)!), m.group(3));
      if (date != null) s = _cut(s, m);
    }
  }
  if (date == null) {
    m = _reMdyName.firstMatch(s);
    if (m != null) {
      date = _resolveMonthDay(today, _months[m.group(1)!.toLowerCase()]!,
          int.parse(m.group(2)!), m.group(3));
      if (date != null) s = _cut(s, m);
    }
  }
  if (date == null) {
    m = _reNumDate.firstMatch(s);
    if (m != null) {
      final a = int.parse(m.group(1)!);
      final b = int.parse(m.group(2)!);
      var day = dayFirst ? a : b;
      var mon = dayFirst ? b : a;
      if (mon > 12 && day <= 12) {
        final t = day;
        day = mon;
        mon = t;
      }
      if (mon >= 1 && mon <= 12 && day >= 1 && day <= 31) {
        date = _resolveMonthDay(today, mon, day, m.group(3));
        if (date != null) s = _cut(s, m);
      }
    }
  }
  if (date == null) {
    m = _reInHalfHour.firstMatch(s);
    if (m != null) {
      minutesOffset = 30;
      s = _cut(s, m);
    }
  }
  if (date == null && minutesOffset == null) {
    m = _reInN.firstMatch(s);
    if (m != null) {
      final raw = m.group(1)!.toLowerCase();
      final n = int.tryParse(raw) ?? _numWords[raw]!;
      switch (m.group(2)!.toLowerCase()) {
        case 'minute':
        case 'min':
          minutesOffset = n;
        case 'hour':
        case 'hr':
          minutesOffset = n * 60;
        case 'day':
          date = _addDays(today, n);
        case 'week':
          date = _addDays(today, 7 * n);
        case 'month':
          date = addMonths(today, n);
        case 'year':
          date = addMonths(today, 12 * n);
      }
      s = _cut(s, m);
    }
  }
  var tonight = false;
  if (date == null && minutesOffset == null) {
    m = _reDayAfter.firstMatch(s);
    if (m != null) {
      date = _addDays(today, 2);
      s = _cut(s, m);
    }
  }
  if (date == null && minutesOffset == null) {
    m = _reRelDay.firstMatch(s);
    if (m != null) {
      final w = m.group(1)!.toLowerCase();
      if (w == 'today') {
        date = today;
      } else if (w == 'tonight') {
        date = today;
        tonight = true;
      } else {
        date = _addDays(today, 1);
      }
      s = _cut(s, m);
    }
  }
  if (date == null && minutesOffset == null) {
    m = _reNextWeek.firstMatch(s);
    if (m != null) {
      date = _addDays(today, 8 - today.weekday);
      s = _cut(s, m);
    }
  }
  if (date == null && minutesOffset == null) {
    m = _reNextMonth.firstMatch(s);
    if (m != null) {
      date = addMonths(DateTime(today.year, today.month, 1), 1);
      s = _cut(s, m);
    }
  }
  if (date == null && minutesOffset == null) {
    m = _reEndMonth.firstMatch(s);
    if (m != null) {
      date = DateTime(today.year, today.month + 1, 0);
      s = _cut(s, m);
    }
  }
  if (date == null && minutesOffset == null) {
    m = _reWeekend.firstMatch(s);
    if (m != null) {
      date = _upcoming(today, 6, true);
      s = _cut(s, m);
    }
  }
  if (date == null && minutesOffset == null) {
    m = _reWdFull.firstMatch(s);
    if (m != null) {
      date = _weekdayDate(today, _weekdays[m.group(2)!.toLowerCase()]!,
          (m.group(1) ?? '').toLowerCase());
      s = _cut(s, m);
    }
  }
  if (date == null && minutesOffset == null) {
    m = _reWdAbbr.firstMatch(s);
    if (m != null) {
      final prefix = m.group(1)!.toLowerCase();
      date = _weekdayDate(today, _weekdayAbbr[m.group(2)!.toLowerCase()]!,
          (prefix == 'next' || prefix == 'this') ? prefix : '');
      s = _cut(s, m);
    }
  }

  // ---- time ----------------------------------------------------------------
  int? hour;
  int? minute;
  m = _reTimeAmPm.firstMatch(s);
  if (m != null) {
    final h = int.parse(m.group(1)!);
    if (h >= 1 && h <= 12) {
      hour = _hour24(h, m.group(3)!);
      minute = int.parse(m.group(2) ?? '0');
      s = _cut(s, m);
    }
  }
  if (hour == null) {
    m = _reTime24.firstMatch(s);
    if (m != null) {
      hour = int.parse(m.group(1)!);
      minute = int.parse(m.group(2)!);
      s = _cut(s, m);
    }
  }
  if (hour == null) {
    m = _reNoon.firstMatch(s);
    if (m != null) {
      hour = 12;
      minute = 0;
      s = _cut(s, m);
    }
  }
  if (hour == null) {
    m = _reMidnight.firstMatch(s);
    if (m != null) {
      hour = 0;
      minute = 0;
      s = _cut(s, m);
    }
  }
  if (hour == null) {
    m = _reTimeAt.firstMatch(s);
    if (m != null) {
      final h = int.parse(m.group(1)!);
      if (h >= 1 && h <= 12) {
        // 1-6 read as afternoon, 7-11 as morning, 12 as noon.
        hour = h <= 6 ? h + 12 : h;
        minute = 0;
        s = _cut(s, m);
      }
    }
  }
  if (hour == null) {
    final rx = (date != null || tonight) ? _rePartOfDay : _rePartOfDayStrict;
    m = rx.firstMatch(s);
    if (m != null) {
      switch (m.group(1)!.toLowerCase()) {
        case 'morning':
          hour = 9;
        case 'afternoon':
          hour = 15;
        default:
          hour = 18;
      }
      minute = 0;
      s = _cut(s, m);
    }
  }
  if (hour == null && tonight) {
    hour = 20;
    minute = 0;
  }

  // ---- assemble the due date -------------------------------------------------
  bool passed(int h, int mi) =>
      !DateTime(today.year, today.month, today.day, h, mi).isAfter(nowT);

  if (minutesOffset != null) {
    out.due = DateTime(nowT.year, nowT.month, nowT.day, nowT.hour, nowT.minute)
        .add(Duration(minutes: minutesOffset));
    out.hasTime = true;
  } else {
    if (date == null && out.repeat != null && anchorWd != null) {
      date = _upcoming(today, anchorWd, true);
      if (date == today && hour != null && passed(hour, minute ?? 0)) {
        date = _addDays(today, 7);
      }
    }
    if (date == null && hour != null) {
      date = today;
      if (passed(hour, minute ?? 0)) date = _addDays(today, 1);
    }
    if (date == null && out.repeat != null) date = today;
    if (date != null) {
      out.due = DateTime(date.year, date.month, date.day, hour ?? 0, minute ?? 0);
      out.hasTime = hour != null;
    }
  }

  out.title = _cleanTitle(s.replaceAll(_reTag, ' '));
  if (out.title.isEmpty) out.title = _cleanTitle(original);

  final fw = RegExp(r"^[A-Za-z']+").firstMatch(out.title);
  final verbStart = fw != null && _taskVerbs.contains(fw.group(0)!.toLowerCase());
  final short = out.title.split(' ').length <= 12 && !text.trim().contains('\n');
  out.isTask = explicitTask ||
      out.due != null ||
      out.priority != 0 ||
      out.repeat != null ||
      (verbStart && short);
  if (!out.isTask) {
    final body = text.trim().replaceAll(_reTag, '').trim();
    final tb = _noteTitleBody(body.replaceAll(RegExp(r'[ \t]+'), ' '));
    out.title = tb.$1;
    out.body = tb.$2;
  }
  return out;
}
