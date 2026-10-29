import sys
from datetime import datetime
sys.path.insert(0, '.')
from nlp_reference import parse_entry
from cases import CASES, NOW

def dt(t): return None if t is None else datetime(*t)
bad = 0
for text, opts, want in CASES:
    r = parse_entry(text, now=datetime(*NOW), day_first=opts.get('day_first', True))
    got = dict(title=r.title, due=r.due, has_time=r.has_time, priority=r.priority, tags=r.tags,
               repeat=(r.repeat.unit, r.repeat.interval) if r.repeat else None, is_task=r.is_task)
    for k, v in want.items():
        exp = dt(v) if k == 'due' else v
        if got[k] != exp:
            bad += 1
            print(f'FAIL {text!r} [{opts}] {k}: got {got[k]!r} want {exp!r}')
print(f'{len(CASES)} cases, {bad} field mismatches')
sys.exit(1 if bad else 0)
