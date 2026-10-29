import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Keeps the foreground app and the background worker from stepping on each
/// other. They share the same files but run in separate isolates, so they
/// coordinate through two tiny marker files in the notes folder:
///
///  * `app_active`: touched every few seconds while the app is in the
///    foreground. The worker skips its run when this is fresh.
///  * `bg.lock`: held by whichever side is syncing right now (foreground or
///    worker), so two syncs never overlap. A crashed holder expires.
class WorkerGuard {
  WorkerGuard(this.dir);

  final Directory dir;

  static const Duration activeWindow = Duration(seconds: 75);
  static const Duration lockExpiry = Duration(minutes: 8);

  File get _active => File(p.join(dir.path, 'app_active'));
  File get _lock => File(p.join(dir.path, 'bg.lock'));

  Future<int?> _stamp(File f) async {
    try {
      if (!await f.exists()) return null;
      return int.tryParse((await f.readAsString()).trim());
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(File f) async {
    try {
      await f.writeAsString(DateTime.now().millisecondsSinceEpoch.toString(), flush: true);
    } catch (_) {}
  }

  Future<void> markActive() => _write(_active);

  Future<void> markInactive() async {
    try {
      if (await _active.exists()) await _active.delete();
    } catch (_) {}
  }

  Future<bool> isAppActive() async {
    final t = await _stamp(_active);
    return t != null &&
        DateTime.now().millisecondsSinceEpoch - t < activeWindow.inMilliseconds;
  }

  Future<bool> isLocked() async {
    final t = await _stamp(_lock);
    return t != null &&
        DateTime.now().millisecondsSinceEpoch - t < lockExpiry.inMilliseconds;
  }

  /// Takes the sync lock. Returns false when somebody else holds it.
  Future<bool> tryAcquire() async {
    if (await isLocked()) return false;
    await _write(_lock);
    return true;
  }

  Future<void> release() async {
    try {
      if (await _lock.exists()) await _lock.delete();
    } catch (_) {}
  }

  /// Waits (up to [timeout]) for a running sync to finish, e.g. when the app
  /// is opened while the worker is mid-sync.
  Future<void> waitForRelease({Duration timeout = const Duration(seconds: 20)}) async {
    final end = DateTime.now().add(timeout);
    while (await isLocked() && DateTime.now().isBefore(end)) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
}
