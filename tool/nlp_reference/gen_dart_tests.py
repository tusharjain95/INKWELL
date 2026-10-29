import sys
sys.path.insert(0, '.')
from cases import CASES, NOW

def q(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'").replace('$', '\\$') + "'"

def dtl(t):
    return 'DateTime(' + ', '.join(str(x) for x in t) + ')'

lines = []
lines.append("""// GENERATED from the table-driven cases of the Python reference parser
// (tool/nlp_reference/cases.py). Edit the table, not this file.
import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/models.dart';
import 'package:inkwell/core/nlp.dart';

final DateTime _now = %s; // a Wednesday

void main() {
  group('parseEntry', () {""" % dtl(NOW))
seen = {}
for text, opts, want in CASES:
    name = text if text else '(empty input)'
    if opts.get('day_first') is False:
        name += ' [month first]'
    seen[name] = seen.get(name, 0) + 1
    if seen[name] > 1:
        name += f' #{seen[name]}'
    args = '_now'
    call = f"parseEntry({q(text)}, now: {args}" + (", dayFirst: false" if opts.get('day_first') is False else "") + ")"
    lines.append(f"    test({q(name)}, () {{")
    lines.append(f"      final r = {call};")
    for k, v in want.items():
        if k == 'title':
            lines.append(f"      expect(r.title, {q(v)});")
        elif k == 'due':
            lines.append("      expect(r.due, isNull);" if v is None else f"      expect(r.due, {dtl(v)});")
        elif k == 'has_time':
            lines.append(f"      expect(r.hasTime, {str(v).lower()});")
        elif k == 'priority':
            lines.append(f"      expect(r.priority, {v});")
        elif k == 'tags':
            lines.append("      expect(r.tags, [" + ', '.join(q(t) for t in v) + "]);")
        elif k == 'repeat':
            lines.append(f"      expect(r.repeat, const Repeat({q(v[0])}, {v[1]}));")
        elif k == 'is_task':
            lines.append(f"      expect(r.isTask, {str(v).lower()});")
        else:
            raise SystemExit('unknown key ' + k)
    lines.append("    });")
lines.append("  });\n}")
open('../../test/nlp_test.dart', 'w').write('\n'.join(lines) + '\n')
print('wrote', len(CASES), 'cases')
