"""Reference implementation of the Inkwell natural-language parser.
The Dart port (lib/core/nlp.dart) mirrors this one regex for regex, so the
cases below double as the Dart test-suite."""
import re
import calendar
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Optional

WEEKDAYS = {
    'monday': 1, 'tuesday': 2, 'wednesday': 3, 'thursday': 4,
    'friday': 5, 'saturday': 6, 'sunday': 7,
}
WEEKDAY_ABBR = {
    'mon': 1, 'tue': 2, 'tues': 2, 'wed': 3, 'thu': 4, 'thur': 4,
    'thurs': 4, 'fri': 5, 'sat': 6, 'sun': 7,
}
MONTHS = {
    'january': 1, 'jan': 1, 'february': 2, 'feb': 2, 'march': 3, 'mar': 3,
    'april': 4, 'apr': 4, 'may': 5, 'june': 6, 'jun': 6, 'july': 7, 'jul': 7,
    'august': 8, 'aug': 8, 'september': 9, 'sep': 9, 'sept': 9,
    'october': 10, 'oct': 10, 'november': 11, 'nov': 11,
    'december': 12, 'dec': 12,
}
NUMWORDS = {
    'a': 1, 'an': 1, 'one': 1, 'two': 2, 'three': 3, 'four': 4, 'five': 5,
    'six': 6, 'seven': 7, 'eight': 8, 'nine': 9, 'ten': 10, 'twelve': 12,
}
TASK_VERBS = {
    'call', 'buy', 'email', 'text', 'message', 'send', 'pay', 'book',
    'schedule', 'submit', 'finish', 'complete', 'renew', 'order', 'pick',
    'drop', 'clean', 'fix', 'update', 'review', 'prepare', 'plan', 'file',
    'follow', 'check', 'ask', 'cancel', 'collect', 'deliver', 'print',
    'sign', 'return', 'register', 'apply', 'visit', 'meet', 'organise',
    'organize', 'arrange', 'confirm', 'remind', 'water', 'wash', 'cook',
}

_WD_FULL = '|'.join(WEEKDAYS)
_WD_ABBR = '|'.join(sorted(WEEKDAY_ABBR, key=len, reverse=True))
_MONTH = '|'.join(sorted(MONTHS, key=len, reverse=True))

I = re.IGNORECASE
RE_TASK_PREFIX = re.compile(
    r"^\s*(?:remind me(?: to| that| about)?|reminder:?|don'?t forget to|"
    r"to-?do:?|task:?|add (?:a )?task(?: to)?:?|i need to|i have to|i must)\s+", I)
RE_NOTE_PREFIX = re.compile(
    r"^\s*(?:note(?: to self)?\s*:|note to self\s+|note that\s+|jot down\s+|write down\s+)", I)

RE_EVERY_N = re.compile(r'\bevery\s+(\d+)\s*(day|week|month|year)s?\b', I)
RE_EVERY_OTHER = re.compile(r'\bevery\s+other\s+(day|week|month|year)\b', I)
RE_EVERY_UNIT = re.compile(r'\bevery\s+(day|week|month|year)\b', I)
RE_EVERY_WD = re.compile(r'\bevery\s+(' + _WD_FULL + r')s?\b', I)
RE_ADVERB = re.compile(r'\b(daily|weekly|monthly|yearly|annually)\b', I)

RE_PRIO_BANG = re.compile(r'(?<![\w])!([123])(?!\d)')
RE_PRIO_HIGH = re.compile(r'\b(?:urgent|asap|high priority|top priority)\b:?', I)
RE_PRIO_MED = re.compile(r'\bmedium priority\b', I)
RE_PRIO_LOW = re.compile(r'\blow priority\b', I)
RE_TAG = re.compile(r'(?<![\w&])#([A-Za-z][\w-]*)')

RE_ISO = re.compile(r'\b(\d{4})-(\d{1,2})-(\d{1,2})\b')
RE_DMY_NAME = re.compile(
    r'\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(' + _MONTH + r')\b(?:,?\s+(\d{4})\b)?', I)
RE_MDY_NAME = re.compile(
    r'\b(' + _MONTH + r')\s+(\d{1,2})(?:st|nd|rd|th)?\b(?:,?\s+(\d{4})\b)?', I)
RE_NUM_DATE = re.compile(r'\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b')
RE_IN_N = re.compile(
    r'\bin\s+(\d+|an?|one|two|three|four|five|six|seven|eight|nine|ten|twelve)\s+'
    r'(minute|min|hour|hr|day|week|month|year)s?\b', I)
RE_IN_HALF_HOUR = re.compile(r'\bin\s+half\s+an?\s+hour\b', I)
RE_DAY_AFTER = re.compile(r'\bday after tomorrow\b', I)
RE_REL_DAY = re.compile(r'\b(today|tonight|tomorrow|tmrw|tmr)\b', I)
RE_WD_FULL = re.compile(r'\b(?:(next|this|coming)\s+)?(' + _WD_FULL + r')\b', I)
RE_WD_ABBR = re.compile(r'\b(on|by|before|until|next|this)\s+(' + _WD_ABBR + r')\b', I)
RE_NEXT_WEEK = re.compile(r'\bnext week\b', I)
RE_NEXT_MONTH = re.compile(r'\bnext month\b', I)
RE_WEEKEND = re.compile(r'\b(?:this\s+)?weekend\b', I)
RE_END_MONTH = re.compile(r'\bend of (?:the )?month\b', I)

RE_TIME_AMPM = re.compile(
    r'\b(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)(?!\w)', I)
RE_TIME_24 = re.compile(r'\b(?:at\s+)?([01]?\d|2[0-3]):([0-5]\d)\b', I)
RE_TIME_AT = re.compile(r'\bat\s+(\d{1,2})\b(?!\s*[/:\-.\d])', I)
RE_NOON = re.compile(r'\bnoon\b', I)
RE_MIDNIGHT = re.compile(r'\bmidnight\b', I)
RE_PART_OF_DAY = re.compile(r'\b(?:(?:in\s+the|this)\s+)?(morning|afternoon|evening)\b', I)
RE_PART_OF_DAY_STRICT = re.compile(r'\b(?:in\s+the|this)\s+(morning|afternoon|evening)\b', I)

RE_DANGLING_START = re.compile(r'^(?:(?:on|at|by|before|until|due|for|in|from|to)\b[\s,]*)+', I)
RE_DANGLING_END = re.compile(r'(?:[\s,]*\b(?:on|at|by|before|until|due|for|in|from|to|every|next|this))+$', I)


@dataclass
class Repeat:
    unit: str
    interval: int = 1


@dataclass
class Parsed:
    title: str = ''
    body: str = ''
    due: Optional[datetime] = None
    has_time: bool = False
    priority: int = 0
    tags: list = field(default_factory=list)
    repeat: Optional[Repeat] = None
    is_task: bool = False


def _cut(s, m):
    return s[:m.start()] + ' ' + s[m.end():]


def _add_months(d, n):
    idx = d.month - 1 + n
    y = d.year + idx // 12
    m = idx % 12 + 1
    day = min(d.day, calendar.monthrange(y, m)[1])
    return d.replace(year=y, month=m, day=day)


def _upcoming(today, wd, include_today):
    delta = (wd - today.isoweekday()) % 7
    if delta == 0 and not include_today:
        delta = 7
    return today + timedelta(days=delta)


def _hour24(h, mer):
    mer = mer.lower().replace('.', '')
    if mer == 'am':
        return h % 12
    return h % 12 + 12


def _capitalise(s):
    return s[:1].upper() + s[1:] if s else s


def _clean_title(s):
    s = re.sub(r'\s+', ' ', s).strip()
    prev = None
    while prev != s:
        prev = s
        s = RE_DANGLING_START.sub('', s).strip()
        s = RE_DANGLING_END.sub('', s).strip()
        s = re.sub(r'^[\s,.;:\-–]+|[\s,;:\-–]+$', '', s)
    return _capitalise(s.strip())


def parse_entry(text, now=None, day_first=True):
    now = now or datetime.now()
    today = datetime(now.year, now.month, now.day)
    s = re.sub(r'\s+', ' ', text.replace('\n', ' ')).strip() if '\n' not in text.strip() else text.strip()
    original = s
    out = Parsed()

    explicit_task = False
    force_note = False
    m = RE_TASK_PREFIX.match(s)
    if m:
        explicit_task = True
        s = s[m.end():]
    else:
        m = RE_NOTE_PREFIX.match(s)
        if m:
            force_note = True
            s = s[m.end():].strip()
            original = s

    # tags work for notes and tasks
    for m in list(RE_TAG.finditer(s)):
        t = m.group(1).lower()
        if t not in out.tags:
            out.tags.append(t)
    s = RE_TAG.sub(' ', s)

    if force_note:
        out.is_task = False
        body = RE_TAG.sub('', original).strip()
        body = re.sub(r'[ \t]+', ' ', body)
        out.title, out.body = _note_title_body(body)
        return out

    # priority
    m = RE_PRIO_BANG.search(s)
    if m:
        out.priority = int(m.group(1))
        s = _cut(s, m)
    for rx, pr in ((RE_PRIO_HIGH, 1), (RE_PRIO_MED, 2), (RE_PRIO_LOW, 3)):
        m = rx.search(s)
        if m:
            if out.priority == 0:
                out.priority = pr
            s = _cut(s, m)

    # recurrence
    anchor_wd = None
    m = RE_EVERY_N.search(s)
    if m:
        out.repeat = Repeat(m.group(2).lower(), max(1, int(m.group(1))))
        s = _cut(s, m)
    if out.repeat is None:
        m = RE_EVERY_OTHER.search(s)
        if m:
            out.repeat = Repeat(m.group(1).lower(), 2)
            s = _cut(s, m)
    if out.repeat is None:
        m = RE_EVERY_WD.search(s)
        if m:
            out.repeat = Repeat('week', 1)
            anchor_wd = WEEKDAYS[m.group(1).lower()]
            s = _cut(s, m)
    if out.repeat is None:
        m = RE_EVERY_UNIT.search(s)
        if m:
            out.repeat = Repeat(m.group(1).lower(), 1)
            s = _cut(s, m)
    if out.repeat is None:
        m = RE_ADVERB.search(s)
        if m:
            unit = {'daily': 'day', 'weekly': 'week', 'monthly': 'month',
                    'yearly': 'year', 'annually': 'year'}[m.group(1).lower()]
            out.repeat = Repeat(unit, 1)
            s = _cut(s, m)

    # ---- date -------------------------------------------------------------
    date = None
    minutes_offset = None  # relative "in 2 hours"

    def set_date(d):
        nonlocal date
        date = d

    m = RE_ISO.search(s)
    if m:
        try:
            set_date(datetime(int(m.group(1)), int(m.group(2)), int(m.group(3))))
            s = _cut(s, m)
        except ValueError:
            pass
    if date is None:
        m = RE_DMY_NAME.search(s)
        if m:
            day, mon = int(m.group(1)), MONTHS[m.group(2).lower()]
            date = _resolve_month_day(today, mon, day, m.group(3))
            if date is not None:
                s = _cut(s, m)
    if date is None:
        m = RE_MDY_NAME.search(s)
        if m:
            mon, day = MONTHS[m.group(1).lower()], int(m.group(2))
            date = _resolve_month_day(today, mon, day, m.group(3))
            if date is not None:
                s = _cut(s, m)
    if date is None:
        m = RE_NUM_DATE.search(s)
        if m:
            a, b = int(m.group(1)), int(m.group(2))
            day, mon = (a, b) if day_first else (b, a)
            if mon > 12 and day <= 12:
                day, mon = mon, day
            if 1 <= mon <= 12 and 1 <= day <= 31:
                date = _resolve_month_day(today, mon, day, m.group(3))
                if date is not None:
                    s = _cut(s, m)
    if date is None:
        m = RE_IN_HALF_HOUR.search(s)
        if m:
            minutes_offset = 30
            s = _cut(s, m)
    if date is None and minutes_offset is None:
        m = RE_IN_N.search(s)
        if m:
            raw = m.group(1).lower()
            n = int(raw) if raw.isdigit() else NUMWORDS[raw]
            unit = m.group(2).lower()
            if unit in ('minute', 'min'):
                minutes_offset = n
            elif unit in ('hour', 'hr'):
                minutes_offset = n * 60
            elif unit == 'day':
                date = today + timedelta(days=n)
            elif unit == 'week':
                date = today + timedelta(days=7 * n)
            elif unit == 'month':
                date = _add_months(today, n)
            elif unit == 'year':
                date = _add_months(today, 12 * n)
            s = _cut(s, m)
    tonight = False
    if date is None and minutes_offset is None:
        m = RE_DAY_AFTER.search(s)
        if m:
            date = today + timedelta(days=2)
            s = _cut(s, m)
    if date is None and minutes_offset is None:
        m = RE_REL_DAY.search(s)
        if m:
            w = m.group(1).lower()
            if w == 'today':
                date = today
            elif w == 'tonight':
                date = today
                tonight = True
            else:
                date = today + timedelta(days=1)
            s = _cut(s, m)
    if date is None and minutes_offset is None:
        m = RE_NEXT_WEEK.search(s)
        if m:
            date = today + timedelta(days=8 - today.isoweekday())
            s = _cut(s, m)
    if date is None and minutes_offset is None:
        m = RE_NEXT_MONTH.search(s)
        if m:
            first = today.replace(day=1)
            date = _add_months(first, 1)
            s = _cut(s, m)
    if date is None and minutes_offset is None:
        m = RE_END_MONTH.search(s)
        if m:
            date = today.replace(day=calendar.monthrange(today.year, today.month)[1])
            s = _cut(s, m)
    if date is None and minutes_offset is None:
        m = RE_WEEKEND.search(s)
        if m:
            date = _upcoming(today, 6, True)
            s = _cut(s, m)
    if date is None and minutes_offset is None:
        m = RE_WD_FULL.search(s)
        if m:
            date = _weekday_date(today, WEEKDAYS[m.group(2).lower()], (m.group(1) or '').lower())
            s = _cut(s, m)
    if date is None and minutes_offset is None:
        m = RE_WD_ABBR.search(s)
        if m:
            date = _weekday_date(today, WEEKDAY_ABBR[m.group(2).lower()],
                                 m.group(1).lower() if m.group(1).lower() in ('next', 'this') else '')
            s = _cut(s, m)

    # ---- time ---------------------------------------------------------------
    hour = minute = None
    m = RE_TIME_AMPM.search(s)
    if m:
        h = int(m.group(1))
        if 1 <= h <= 12:
            hour, minute = _hour24(h, m.group(3)), int(m.group(2) or 0)
            s = _cut(s, m)
    if hour is None:
        m = RE_TIME_24.search(s)
        if m:
            hour, minute = int(m.group(1)), int(m.group(2))
            s = _cut(s, m)
    if hour is None:
        m = RE_NOON.search(s)
        if m:
            hour, minute = 12, 0
            s = _cut(s, m)
    if hour is None:
        m = RE_MIDNIGHT.search(s)
        if m:
            hour, minute = 0, 0
            s = _cut(s, m)
    if hour is None:
        m = RE_TIME_AT.search(s)
        if m:
            h = int(m.group(1))
            if 1 <= h <= 12:
                if h <= 6:
                    hour = h + 12
                else:
                    hour = h  # 7-11 stay in the morning, 12 is noon
                minute = 0
                s = _cut(s, m)
    if hour is None:
        rx = RE_PART_OF_DAY if (date is not None or tonight) else RE_PART_OF_DAY_STRICT
        m = rx.search(s)
        if m:
            part = m.group(1).lower()
            hour, minute = {'morning': (9, 0), 'afternoon': (15, 0), 'evening': (18, 0)}[part]
            s = _cut(s, m)
    if hour is None and tonight:
        hour, minute = 20, 0

    # ---- assemble due ---------------------------------------------------------
    if minutes_offset is not None:
        out.due = now.replace(second=0, microsecond=0) + timedelta(minutes=minutes_offset)
        out.has_time = True
    else:
        if date is None and out.repeat is not None and anchor_wd:
            date = _upcoming(today, anchor_wd, True)
            if date == today and hour is not None and \
                    datetime(today.year, today.month, today.day, hour, minute) <= now:
                date = today + timedelta(days=7)
        if date is None and hour is not None:
            date = today
            if datetime(today.year, today.month, today.day, hour, minute) <= now:
                date = today + timedelta(days=1)
        if date is None and out.repeat is not None:
            date = today
        if date is not None:
            out.due = date.replace(hour=hour or 0, minute=minute or 0)
            out.has_time = hour is not None

    out.title = _clean_title(RE_TAG.sub(' ', s))
    if not out.title:
        out.title = _clean_title(original)

    first_word = re.match(r"[A-Za-z']+", out.title)
    verb_start = bool(first_word and first_word.group(0).lower() in TASK_VERBS)
    short = len(out.title.split()) <= 12 and '\n' not in text.strip()
    out.is_task = (explicit_task or out.due is not None or out.priority != 0
                   or out.repeat is not None or (verb_start and short))
    if not out.is_task:
        body = RE_TAG.sub('', text.strip()).strip()
        out.title, out.body = _note_title_body(re.sub(r'[ \t]+', ' ', body))
    return out


def _weekday_date(today, wd, modifier):
    if modifier == 'next':
        start = today + timedelta(days=8 - today.isoweekday())
        return start + timedelta(days=wd - 1)
    if modifier in ('this', 'coming'):
        return _upcoming(today, wd, True)
    return _upcoming(today, wd, False)


def _resolve_month_day(today, mon, day, year_str):
    try:
        if year_str:
            y = int(year_str)
            if y < 100:
                y += 2000
            return datetime(y, mon, day)
        d = datetime(today.year, mon, day)
        if d < today:
            d = datetime(today.year + 1, mon, day)
        return d
    except ValueError:
        return None


def _note_title_body(text):
    text = text.strip()
    if not text:
        return '', ''
    first_line = text.split('\n', 1)[0].strip()
    if len(first_line) <= 60 and ('\n' in text or len(text) <= 60):
        title = first_line
        body = text[len(first_line):].strip() if '\n' in text else ''
        return _capitalise(title.rstrip('.')), body
    cut = first_line[:60]
    if ' ' in cut:
        cut = cut[:cut.rfind(' ')]
    return _capitalise(cut.strip(' ,;:-')) + '…', text
