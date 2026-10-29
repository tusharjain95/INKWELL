// GENERATED from the table-driven cases of the Python reference parser
// (tool/nlp_reference/cases.py). Edit the table, not this file.
import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/models.dart';
import 'package:inkwell/core/nlp.dart';

final DateTime _now = DateTime(2026, 10, 28, 9, 0); // a Wednesday

void main() {
  group('parseEntry', () {
    test('Buy milk tomorrow 5pm', () {
      final r = parseEntry('Buy milk tomorrow 5pm', now: _now);
      expect(r.title, 'Buy milk');
      expect(r.due, DateTime(2026, 10, 29, 17, 0));
      expect(r.hasTime, true);
      expect(r.isTask, true);
    });
    test('call Rahul on friday at 3:30pm !1 #work', () {
      final r = parseEntry('call Rahul on friday at 3:30pm !1 #work', now: _now);
      expect(r.title, 'Call Rahul');
      expect(r.due, DateTime(2026, 10, 30, 15, 30));
      expect(r.priority, 1);
      expect(r.tags, ['work']);
    });
    test('Gym every monday 7am', () {
      final r = parseEntry('Gym every monday 7am', now: _now);
      expect(r.title, 'Gym');
      expect(r.repeat, const Repeat('week', 1));
      expect(r.due, DateTime(2026, 11, 2, 7, 0));
    });
    test('pay rent in 3 days', () {
      final r = parseEntry('pay rent in 3 days', now: _now);
      expect(r.title, 'Pay rent');
      expect(r.due, DateTime(2026, 10, 31));
      expect(r.hasTime, false);
    });
    test('remind me to submit GST return by 20 nov', () {
      final r = parseEntry('remind me to submit GST return by 20 nov', now: _now);
      expect(r.title, 'Submit GST return');
      expect(r.due, DateTime(2026, 11, 20));
      expect(r.isTask, true);
    });
    test('Idea: a blog about gardening', () {
      final r = parseEntry('Idea: a blog about gardening', now: _now);
      expect(r.title, 'Idea: a blog about gardening');
      expect(r.isTask, false);
      expect(r.due, isNull);
    });
    test('note: meeting went well, follow up tomorrow', () {
      final r = parseEntry('note: meeting went well, follow up tomorrow', now: _now);
      expect(r.title, 'Meeting went well, follow up tomorrow');
      expect(r.isTask, false);
      expect(r.due, isNull);
    });
    test('dentist next friday 10am', () {
      final r = parseEntry('dentist next friday 10am', now: _now);
      expect(r.title, 'Dentist');
      expect(r.due, DateTime(2026, 11, 6, 10, 0));
    });
    test('submit report tonight', () {
      final r = parseEntry('submit report tonight', now: _now);
      expect(r.title, 'Submit report');
      expect(r.due, DateTime(2026, 10, 28, 20, 0));
    });
    test('meeting at 5', () {
      final r = parseEntry('meeting at 5', now: _now);
      expect(r.title, 'Meeting');
      expect(r.due, DateTime(2026, 10, 28, 17, 0));
    });
    test('wake up at 6am', () {
      final r = parseEntry('wake up at 6am', now: _now);
      expect(r.due, DateTime(2026, 10, 29, 6, 0));
    });
    test('check oven in 2 hours', () {
      final r = parseEntry('check oven in 2 hours', now: _now);
      expect(r.title, 'Check oven');
      expect(r.due, DateTime(2026, 10, 28, 11, 0));
      expect(r.hasTime, true);
    });
    test('lunch with Sam 12/11', () {
      final r = parseEntry('lunch with Sam 12/11', now: _now);
      expect(r.due, DateTime(2026, 11, 12));
    });
    test('lunch with Sam 12/11 [month first]', () {
      final r = parseEntry('lunch with Sam 12/11', now: _now, dayFirst: false);
      expect(r.due, DateTime(2026, 12, 11));
    });
    test('lunch with Sam 12/11/26', () {
      final r = parseEntry('lunch with Sam 12/11/26', now: _now);
      expect(r.due, DateTime(2026, 11, 12));
    });
    test('pay bill 5th nov', () {
      final r = parseEntry('pay bill 5th nov', now: _now);
      expect(r.title, 'Pay bill');
      expect(r.due, DateTime(2026, 11, 5));
    });
    test('dentist october 30 2pm', () {
      final r = parseEntry('dentist october 30 2pm', now: _now);
      expect(r.title, 'Dentist');
      expect(r.due, DateTime(2026, 10, 30, 14, 0));
    });
    test('buy gift next month', () {
      final r = parseEntry('buy gift next month', now: _now);
      expect(r.due, DateTime(2026, 11, 1));
    });
    test('review contract end of month', () {
      final r = parseEntry('review contract end of month', now: _now);
      expect(r.due, DateTime(2026, 10, 31));
    });
    test('water plants every 2 weeks', () {
      final r = parseEntry('water plants every 2 weeks', now: _now);
      expect(r.title, 'Water plants');
      expect(r.repeat, const Repeat('week', 2));
      expect(r.due, DateTime(2026, 10, 28));
    });
    test('Call mom', () {
      final r = parseEntry('Call mom', now: _now);
      expect(r.isTask, true);
      expect(r.due, isNull);
    });
    test('urgent: file ITR', () {
      final r = parseEntry('urgent: file ITR', now: _now);
      expect(r.title, 'File ITR');
      expect(r.priority, 1);
    });
    test('standup every day at 10am', () {
      final r = parseEntry('standup every day at 10am', now: _now);
      expect(r.repeat, const Repeat('day', 1));
      expect(r.due, DateTime(2026, 10, 28, 10, 0));
    });
    test('book flights day after tomorrow', () {
      final r = parseEntry('book flights day after tomorrow', now: _now);
      expect(r.due, DateTime(2026, 10, 30));
    });
    test('team sync next week', () {
      final r = parseEntry('team sync next week', now: _now);
      expect(r.due, DateTime(2026, 11, 2));
    });
    test('call bank on mon', () {
      final r = parseEntry('call bank on mon', now: _now);
      expect(r.title, 'Call bank');
      expect(r.due, DateTime(2026, 11, 2));
    });
    test('sun cream is in the bag', () {
      final r = parseEntry('sun cream is in the bag', now: _now);
      expect(r.due, isNull);
    });
    test('morning routine ideas', () {
      final r = parseEntry('morning routine ideas', now: _now);
      expect(r.title, 'Morning routine ideas');
      expect(r.due, isNull);
    });
    test('send invoice tomorrow morning', () {
      final r = parseEntry('send invoice tomorrow morning', now: _now);
      expect(r.due, DateTime(2026, 10, 29, 9, 0));
    });
    test('call dad this friday', () {
      final r = parseEntry('call dad this friday', now: _now);
      expect(r.due, DateTime(2026, 10, 30));
    });
    test('call dad wednesday', () {
      final r = parseEntry('call dad wednesday', now: _now);
      expect(r.due, DateTime(2026, 11, 4));
    });
    test('pay tax 2026-12-31', () {
      final r = parseEntry('pay tax 2026-12-31', now: _now);
      expect(r.due, DateTime(2026, 12, 31));
    });
    test('renew insurance in half an hour', () {
      final r = parseEntry('renew insurance in half an hour', now: _now);
      expect(r.due, DateTime(2026, 10, 28, 9, 30));
    });
    test('sign contract noon tomorrow', () {
      final r = parseEntry('sign contract noon tomorrow', now: _now);
      expect(r.due, DateTime(2026, 10, 29, 12, 0));
    });
    test('birthday party on 25 december', () {
      final r = parseEntry('birthday party on 25 december', now: _now);
      expect(r.due, DateTime(2026, 12, 25));
    });
    test('file return 2 jan', () {
      final r = parseEntry('file return 2 jan', now: _now);
      expect(r.due, DateTime(2027, 1, 2));
    });
    test('Weekly report every friday 4pm #work', () {
      final r = parseEntry('Weekly report every friday 4pm #work', now: _now);
      expect(r.repeat, const Repeat('week', 1));
      expect(r.due, DateTime(2026, 10, 30, 16, 0));
      expect(r.tags, ['work']);
    });
    test('Just a thought about the roadmap #ideas', () {
      final r = parseEntry('Just a thought about the roadmap #ideas', now: _now);
      expect(r.title, 'Just a thought about the roadmap');
      expect(r.isTask, false);
      expect(r.tags, ['ideas']);
    });
    test('(empty input)', () {
      final r = parseEntry('', now: _now);
      expect(r.title, '');
      expect(r.due, isNull);
      expect(r.isTask, false);
    });
  });
}
