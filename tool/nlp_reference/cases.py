"""Single source of truth for parser behaviour. test_nlp.py runs these against
the Python reference; gen_dart_tests.py turns the same table into test/nlp_test.dart."""
NOW = (2026, 10, 28, 9, 0)  # Wednesday 09:00

def D(*a): return a  # (y, m, d[, h, mi])

# (text, options, expected-subset)
CASES = [
 ('Buy milk tomorrow 5pm', {}, dict(title='Buy milk', due=D(2026,10,29,17,0), has_time=True, is_task=True)),
 ('call Rahul on friday at 3:30pm !1 #work', {}, dict(title='Call Rahul', due=D(2026,10,30,15,30), priority=1, tags=['work'])),
 ('Gym every monday 7am', {}, dict(title='Gym', repeat=('week',1), due=D(2026,11,2,7,0))),
 ('pay rent in 3 days', {}, dict(title='Pay rent', due=D(2026,10,31), has_time=False)),
 ('remind me to submit GST return by 20 nov', {}, dict(title='Submit GST return', due=D(2026,11,20), is_task=True)),
 ('Idea: a blog about gardening', {}, dict(title='Idea: a blog about gardening', is_task=False, due=None)),
 ('note: meeting went well, follow up tomorrow', {}, dict(title='Meeting went well, follow up tomorrow', is_task=False, due=None)),
 ('dentist next friday 10am', {}, dict(title='Dentist', due=D(2026,11,6,10,0))),
 ('submit report tonight', {}, dict(title='Submit report', due=D(2026,10,28,20,0))),
 ('meeting at 5', {}, dict(title='Meeting', due=D(2026,10,28,17,0))),
 ('wake up at 6am', {}, dict(due=D(2026,10,29,6,0))),
 ('check oven in 2 hours', {}, dict(title='Check oven', due=D(2026,10,28,11,0), has_time=True)),
 ('lunch with Sam 12/11', {}, dict(due=D(2026,11,12))),
 ('lunch with Sam 12/11', {'day_first': False}, dict(due=D(2026,12,11))),
 ('lunch with Sam 12/11/26', {}, dict(due=D(2026,11,12))),
 ('pay bill 5th nov', {}, dict(title='Pay bill', due=D(2026,11,5))),
 ('dentist october 30 2pm', {}, dict(title='Dentist', due=D(2026,10,30,14,0))),
 ('buy gift next month', {}, dict(due=D(2026,11,1))),
 ('review contract end of month', {}, dict(due=D(2026,10,31))),
 ('water plants every 2 weeks', {}, dict(title='Water plants', repeat=('week',2), due=D(2026,10,28))),
 ('Call mom', {}, dict(is_task=True, due=None)),
 ('urgent: file ITR', {}, dict(title='File ITR', priority=1)),
 ('standup every day at 10am', {}, dict(repeat=('day',1), due=D(2026,10,28,10,0))),
 ('book flights day after tomorrow', {}, dict(due=D(2026,10,30))),
 ('team sync next week', {}, dict(due=D(2026,11,2))),
 ('call bank on mon', {}, dict(title='Call bank', due=D(2026,11,2))),
 ('sun cream is in the bag', {}, dict(due=None)),
 ('morning routine ideas', {}, dict(title='Morning routine ideas', due=None)),
 ('send invoice tomorrow morning', {}, dict(due=D(2026,10,29,9,0))),
 ('call dad this friday', {}, dict(due=D(2026,10,30))),
 ('call dad wednesday', {}, dict(due=D(2026,11,4))),
 ('pay tax 2026-12-31', {}, dict(due=D(2026,12,31))),
 ('renew insurance in half an hour', {}, dict(due=D(2026,10,28,9,30))),
 ('sign contract noon tomorrow', {}, dict(due=D(2026,10,29,12,0))),
 ('birthday party on 25 december', {}, dict(due=D(2026,12,25))),
 ('file return 2 jan', {}, dict(due=D(2027,1,2))),
 ('Weekly report every friday 4pm #work', {}, dict(repeat=('week',1), due=D(2026,10,30,16,0), tags=['work'])),
 ('Just a thought about the roadmap #ideas', {}, dict(title='Just a thought about the roadmap', is_task=False, tags=['ideas'])),
 ('', {}, dict(title='', due=None, is_task=False)),
]
