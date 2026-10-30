import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/reminders.dart';
import 'package:inkwell/core/store.dart';
import 'package:inkwell/sync/github_client.dart';

void main() {
  test('notification ids are stable, positive 31-bit numbers', () {
    final a = ReminderService.idFor('abc123');
    expect(ReminderService.idFor('abc123'), a);
    expect(ReminderService.idFor('abc124'), isNot(a));
    for (final id in ['a', 'zzzzzzzzzzzz', '0123456789abcdef']) {
      final v = ReminderService.idFor(id);
      expect(v, greaterThanOrEqualTo(0));
      expect(v, lessThanOrEqualTo(0x7fffffff));
    }
  });

  test('sync state keeps orphan timestamps through JSON', () {
    final s = SyncState(orphanSince: {'abc': 1700000000000});
    final back = SyncState.fromJson(s.toJson());
    expect(back.orphanSince, {'abc': 1700000000000});
    // Older state files without the field still load.
    expect(SyncState.fromJson({'lastHead': 'x'}).orphanSince, isEmpty);
  });

  test('a delete entry has no sha', () {
    expect(const TreeEntry.delete('inkwell/blobs/x.enc').sha, isNull);
    expect(const TreeEntry('inkwell/notes/a.enc', 'sha1').sha, 'sha1');
  });
}
