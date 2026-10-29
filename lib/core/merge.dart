import 'models.dart';

enum MergeAction {
  /// Nothing to do for this note.
  none,

  /// Remote is newer and local is untouched: adopt the remote copy.
  takeRemote,

  /// Local has changes the remote has not seen: upload them.
  pushLocal,

  /// Both sides changed. Remote is newer, so it wins; the local version is
  /// kept as a separate "conflict copy" note.
  conflictKeepRemote,

  /// Both sides changed. Local is newer, so it wins; the remote version is
  /// kept as a separate "conflict copy" note.
  conflictKeepLocal,
}

/// Decides what to do with one note during a sync.
///
/// [remoteChanged] means the remote copy differs from the version this device
/// last synced. [dirty] means this device edited the note since then.
/// [remote] only needs to be provided when [remoteChanged] is true.
///
/// Nothing is ever lost: a true conflict keeps both versions.
MergeAction decide({
  required Note? local,
  required Note? remote,
  required bool dirty,
  required bool remoteChanged,
}) {
  if (!remoteChanged) {
    return (dirty && local != null) ? MergeAction.pushLocal : MergeAction.none;
  }
  if (remote == null) {
    return local != null ? MergeAction.pushLocal : MergeAction.none;
  }
  if (local == null || !dirty) return MergeAction.takeRemote;
  return remote.updatedAt.isBefore(local.updatedAt)
      ? MergeAction.conflictKeepLocal
      : MergeAction.conflictKeepRemote;
}
