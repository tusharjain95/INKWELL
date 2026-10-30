import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:workmanager/workmanager.dart';

import '../core/reminders.dart';
import '../core/settings.dart';
import '../core/store.dart';
import 'sync_service.dart';
import 'worker_guard.dart';

const String _kTask = 'inkwell-sync';
const String _kUnique = 'inkwell-periodic-sync';

/// Entry point WorkManager runs in a fresh background isolate.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    DartPluginRegistrant.ensureInitialized();
    return runBackgroundSync();
  });
}

/// One background sync run. Returns true so WorkManager does not retry
/// aggressively; the next periodic slot tries again anyway.
Future<bool> runBackgroundSync() async {
  try {
    final root = await NoteStore.defaultRoot();
    final guard = WorkerGuard(root);

    // The user is in the app right now: their foreground sync handles it.
    if (await guard.isAppActive()) return true;

    final settings = await AppSettings.load();
    if (!settings.backgroundSync ||
        !settings.autoSync ||
        !settings.config.isComplete) {
      return true;
    }

    final store = await NoteStore.open();
    final sync = SyncService(store, settings, guard: guard);
    await sync.syncNow(); // takes and releases the shared lock itself
    // Tasks pulled from another device may need new reminders.
    final reminders = ReminderService(settings);
    await reminders.reschedule(store);
    reminders.dispose();
    sync.dispose();
    store.dispose();
    return true;
  } catch (_) {
    return false;
  }
}

/// Android background sync via WorkManager (periodic, at most every 30
/// minutes, only with a network connection and a not-low battery). Does
/// nothing on other platforms; Windows syncs while the app is open.
class BackgroundSync {
  static bool get supported => Platform.isAndroid;

  static Timer? _beat;

  static Future<void> init() async {
    if (!supported) return;
    await Workmanager().initialize(backgroundDispatcher);
  }

  static Future<void> apply({required bool enabled}) async {
    if (!supported) return;
    if (enabled) {
      await Workmanager().registerPeriodicTask(
        _kUnique,
        _kTask,
        frequency: const Duration(minutes: 30),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
      );
    } else {
      await Workmanager().cancelByUniqueName(_kUnique);
    }
  }

  /// Tell the worker the app is in the foreground. Call on start and resume.
  static void startHeartbeat(WorkerGuard guard) {
    if (!supported) return;
    _beat?.cancel();
    unawaited(guard.markActive());
    _beat = Timer.periodic(const Duration(seconds: 20), (_) => guard.markActive());
  }

  /// Call when the app goes to the background.
  static Future<void> stopHeartbeat(WorkerGuard guard) async {
    if (!supported) return;
    _beat?.cancel();
    _beat = null;
    await guard.markInactive();
  }
}
