import 'dart:async';

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncReport {
  const SyncReport({
    this.pulled = 0,
    this.pushed = 0,
    this.uploads = 0,
    this.conflicts = 0,
    this.upToDate = false,
    this.removed = 0,
  });

  final int pulled;
  final int pushed;
  final int uploads;
  final int conflicts;
  final bool upToDate;

  /// Abandoned attachments deleted from the repository.
  final int removed;

  String describe() {
    if (upToDate || (pulled == 0 && pushed == 0 && uploads == 0 && removed == 0)) {
      return 'Everything is up to date.';
    }
    final parts = <String>[
      if (pulled > 0) '$pulled downloaded',
      if (pushed > 0) '$pushed uploaded',
      if (uploads > 0) '$uploads attachment${uploads == 1 ? '' : 's'}',
      if (removed > 0) '$removed unused attachment${removed == 1 ? '' : 's'} removed',
      if (conflicts > 0)
        '$conflicts conflict${conflicts == 1 ? '' : 's'} (both versions kept)',
    ];
    return parts.join(' · ');
  }
}


/// How long an unused attachment stays in the repository before it is deleted.
const Duration kOrphanGrace = Duration(days: 14);

