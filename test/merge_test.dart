import 'package:flutter_test/flutter_test.dart';
import 'package:inkwell/core/merge.dart';
import 'package:inkwell/core/models.dart';

Note _note(String id, int updatedMs, {bool deleted = false}) => Note(
      id: id,
      title: 't$updatedMs',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedMs, isUtc: true),
      deleted: deleted,
    );

void main() {
  group('decide', () {
    test('nothing changed anywhere', () {
      expect(
        decide(local: _note('a', 1), remote: null, dirty: false, remoteChanged: false),
        MergeAction.none,
      );
    });

    test('only local changed -> push', () {
      expect(
        decide(local: _note('a', 2), remote: null, dirty: true, remoteChanged: false),
        MergeAction.pushLocal,
      );
    });

    test('identical copies on both sides are not a conflict', () {
      expect(
        decide(local: _note('a', 4), remote: _note('a', 4), dirty: true, remoteChanged: true),
        MergeAction.takeRemote,
      );
    });

    test('only remote changed -> take remote', () {
      expect(
        decide(local: _note('a', 1), remote: _note('a', 2), dirty: false, remoteChanged: true),
        MergeAction.takeRemote,
      );
    });

    test('new remote note this device has never seen -> take remote', () {
      expect(
        decide(local: null, remote: _note('a', 2), dirty: false, remoteChanged: true),
        MergeAction.takeRemote,
      );
    });

    test('both changed, remote newer -> remote wins, local kept as copy', () {
      expect(
        decide(local: _note('a', 2), remote: _note('a', 5), dirty: true, remoteChanged: true),
        MergeAction.conflictKeepRemote,
      );
    });

    test('both changed, local newer -> local wins, remote kept as copy', () {
      expect(
        decide(local: _note('a', 9), remote: _note('a', 5), dirty: true, remoteChanged: true),
        MergeAction.conflictKeepLocal,
      );
    });

    test('a remote deletion (tombstone) is adopted when local is untouched', () {
      expect(
        decide(
          local: _note('a', 1),
          remote: _note('a', 4, deleted: true),
          dirty: false,
          remoteChanged: true,
        ),
        MergeAction.takeRemote,
      );
    });

    test('local note missing from the remote is pushed', () {
      expect(
        decide(local: _note('a', 1), remote: null, dirty: true, remoteChanged: false),
        MergeAction.pushLocal,
      );
    });
  });

  group('Note json', () {
    test('round trips including attachments', () {
      final n = _note('x', 1234).copyWith(
        tags: ['a', 'b'],
        pinned: true,
        attachments: const [
          AttachmentRef(hash: 'h', name: 'doc.pdf', mime: 'application/pdf', size: 10),
        ],
      );
      final back = Note.fromJson(n.toJson());
      expect(back.id, 'x');
      expect(back.tags, ['a', 'b']);
      expect(back.pinned, isTrue);
      expect(back.attachments.single.isPdf, isTrue);
      expect(back.updatedAt, n.updatedAt);
    });
  });
}
