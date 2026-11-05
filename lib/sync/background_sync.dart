import 'dart:async';
import 'dart:io';
import 'dart:ui' show DartPluginRegistrant;

import 'package:workmanager/workmanager.dart';

import '../core/hub.dart';
import '../core/reminders.dart';
import '../core/settings.dart';
import '../core/store.dart';
import '../core/widget_sync.dart';
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
    final syncOn =
        settings.backgroundSync && settings.autoSync && settings.syncReady;
    final hubOn = settings.hubReady;
    if (!syncOn && !hubOn) return true;

    final store = await NoteStore.open();
    // Telegram and email first, so what it adds is uploaded by the sync below.
    if (hubOn) {
      final hub = HubService(store, settings);
      await hub.tick();
      hub.dispose();
    }
    if (syncOn) {
      final sync = SyncService(store, settings, guard: guard);
      await sync.syncNow(); // takes and releases the shared lock itself
      sync.dispose();
    }
    // Tasks pulled from another device, or added by the hub, may need reminders.
    final reminders = ReminderService(settings);
    await reminders.reschedule(store);
    reminders.dispose();
    // Widgets redraw on their own schedule; just hand them fresh data.
    await WidgetSync.push(store, refresh: false);
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

  static int? _minutes;

  /// Registers (or cancels) the periodic worker. With the Telegram hub on it
  /// runs about every 15 minutes (Android's minimum), otherwise every 30.
  static Future<void> apply({required bool enabled, bool hub = false}) async {
    if (!supported) return;
    final minutes = hub ? 15 : 30;
    if (enabled) {
      if (_minutes == minutes) return; // already registered this way
      if (_minutes != null) await Workmanager().cancelByUniqueName(_kUnique);
      _minutes = minutes;
      await Workmanager().registerPeriodicTask(
        _kUnique,
        _kTask,
        frequency: Duration(minutes: minutes),
        constraints: Constraints(
          networkType: NetworkType.connected,
          requiresBatteryNotLow: true,
        ),
      );
    } else {
      _minutes = null;
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
