import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'models.dart';
import 'settings.dart';
import 'store.dart';

const String _kChannelId = 'task-reminders';
const int _kMaxScheduled = 50;
const Duration _kCatchUp = Duration(hours: 12);

/// Notifies the user when a task is due.
///
/// * Android: each reminder is handed to the OS alarm service, so it fires
///   when the app is closed and again after a reboot.
/// * Windows: unpackaged desktop apps cannot use scheduled toasts, so the app
///   sets its own timers. Reminders fire while Inkwell is running, which
///   includes being minimised to the system tray.
///
/// Everything is local: no server, no network.
class ReminderService {
  ReminderService(this.settings);

  final AppSettings settings;
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _ready = false;
  final Map<int, Timer> _timers = {}; // Windows only
  Timer? _debounce;
  NoteStore? _store;

  /// Set when the user taps a notification; the UI opens that note.
  final ValueNotifier<String?> openNote = ValueNotifier<String?>(null);

  bool get _osScheduler => Platform.isAndroid;
  bool get supported => Platform.isAndroid || Platform.isWindows;

  Future<void> init() async {
    if (_ready || !supported) return;
    tzdata.initializeTimeZones();
    try {
      await _plugin.initialize(
        settings: InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          windows: WindowsInitializationSettings(
            appName: 'Inkwell',
            appUserModelId: 'dev.inkwell.notes',
            guid: '6f1c7a5e-3b0d-4d57-9a3e-2d8f6c0b1e42',
          ),
        ),
        onDidReceiveNotificationResponse: (r) {
          final id = r.payload;
          if (id != null && id.isNotEmpty) openNote.value = id;
        },
      );
      _ready = true;
    } catch (e) {
      debugPrint('Reminders unavailable: $e');
      return;
    }
    try {
      final launch = await _plugin.getNotificationAppLaunchDetails();
      final payload = launch?.notificationResponse?.payload;
      if (launch?.didNotificationLaunchApp == true &&
          payload != null &&
          payload.isNotEmpty) {
        openNote.value = payload;
      }
    } catch (_) {}
  }

  /// Asks Android for notification (13+) and exact-alarm (12+) permission.
  /// Returns whether notifications are allowed.
  Future<bool> requestPermission() async {
    await init();
    if (!_ready) return false;
    if (!Platform.isAndroid) return true;
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    final granted = await android.requestNotificationsPermission() ?? true;
    try {
      if (await android.canScheduleExactNotifications() != true) {
        await android.requestExactAlarmsPermission();
      }
    } catch (_) {}
    return granted;
  }

  /// Keeps reminders in step with the notes while the app is open.
  void attach(NoteStore store) {
    _store = store;
    store.addListener(_onChange);
    settings.addListener(_onChange);
    unawaited(reschedule(store, force: true));
  }

  void dispose() {
    _store?.removeListener(_onChange);
    settings.removeListener(_onChange);
    _debounce?.cancel();
    for (final t in _timers.values) {
      t.cancel();
    }
  }

  void _onChange() {
    final s = _store;
    if (s == null) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), () => reschedule(s));
  }

  // ---------------------------------------------------------------- planning

  /// The moment a task should notify, or null if it should not.
  DateTime? _target(Note n) {
    if (n.deleted || !n.isTask || n.done || n.due == null) return null;
    final d = n.due!;
    return n.dueHasTime
        ? d
        : DateTime(d.year, d.month, d.day, settings.reminderHour);
  }

  static int idFor(String noteId) {
    // FNV-1a, kept within a positive 31-bit range.
    var h = 0x811c9dc5;
    for (final c in noteId.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0x7fffffff;
    }
    return h;
  }

  Map<int, int> _loadHandled() {
    try {
      final raw = settings.getString('reminders.handled');
      if (raw == null) return {};
      return (jsonDecode(raw) as Map)
          .map((k, v) => MapEntry(int.parse(k as String), (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// Brings OS alarms / timers in line with the current tasks.
  ///
  /// [force] re-registers every future reminder (used at app start, because
  /// force-stopping an app can drop its alarms).
  Future<void> reschedule(NoteStore store, {bool force = false}) async {
    if (!supported) return;
    await init();
    if (!_ready) return;

    final handled = _loadHandled(); // id -> target millis already dealt with
    final next = <int, int>{};

    if (!settings.remindersEnabled) {
      await _cancelAll(handled.keys);
      await settings.putString('reminders.handled', '{}');
      return;
    }

    final now = DateTime.now();
    final wanted = <(Note, DateTime)>[];
    for (final n in store.all) {
      final t = _target(n);
      if (t != null) wanted.add((n, t));
    }
    wanted.sort((a, b) => a.$2.compareTo(b.$2));

    // Soonest first; anything already overdue is a catch-up candidate.
    var scheduled = 0;
    for (final (note, t) in wanted) {
      final id = idFor(note.id);
      final ms = t.millisecondsSinceEpoch;
      final same = handled[id] == ms;

      if (!t.isAfter(now)) {
        // Overdue. Notify once if we missed it while not running, but only for
        // tasks that existed before they fell due, and not for old ones.
        final existedBefore = note.updatedAt.toLocal().isBefore(t);
        if (!same && existedBefore && now.difference(t) <= _kCatchUp) {
          await _show(note, id, overdue: true);
        }
        next[id] = ms;
        continue;
      }

      if (scheduled >= _kMaxScheduled) continue;
      scheduled++;
      if (same && !force) {
        next[id] = ms;
        if (!_osScheduler && !_timers.containsKey(id)) _arm(note, id, t);
        continue;
      }
      await _schedule(note, id, t);
      next[id] = ms;
    }

    // Cancel what is no longer wanted (done, deleted, moved, disabled).
    final stale = handled.keys.where((id) => !next.containsKey(id));
    await _cancelAll(stale);

    await settings.putString(
        'reminders.handled', jsonEncode(next.map((k, v) => MapEntry('$k', v))));
  }

  Future<void> _cancelAll(Iterable<int> ids) async {
    for (final id in ids.toList()) {
      _timers.remove(id)?.cancel();
      if (_osScheduler) {
        try {
          await _plugin.cancel(id: id);
        } catch (_) {}
      }
    }
  }

  // --------------------------------------------------------------- delivery

  NotificationDetails get _details => NotificationDetails(
        android: AndroidNotificationDetails(
          _kChannelId,
          'Task reminders',
          channelDescription: 'Alerts when a task is due',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
        ),
        windows: WindowsNotificationDetails(),
      );

  String _body(Note n, {bool overdue = false}) {
    final due = n.due!;
    String two(int v) => v.toString().padLeft(2, '0');
    if (n.dueHasTime) {
      final when = '${two(due.hour)}:${two(due.minute)}';
      return overdue ? 'Was due at $when' : 'Due now · $when';
    }
    return overdue ? 'Was due today' : 'Due today';
  }

  String _title(Note n) => n.title.trim().isEmpty ? 'Task' : n.title.trim();

  Future<void> _schedule(Note n, int id, DateTime at) async {
    if (!_osScheduler) {
      _arm(n, id, at);
      return;
    }
    // A DateTime is an exact instant, so converting through UTC is correct
    // whatever the device's time zone is.
    final when = tz.TZDateTime.from(at.toUtc(), tz.UTC);
    var mode = AndroidScheduleMode.exactAllowWhileIdle;
    try {
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (await android?.canScheduleExactNotifications() != true) {
        // Without the exact-alarm permission Android may delay it a few
        // minutes, which is still better than not notifying.
        mode = AndroidScheduleMode.inexactAllowWhileIdle;
      }
    } catch (_) {
      mode = AndroidScheduleMode.inexactAllowWhileIdle;
    }
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: _title(n),
        body: _body(n),
        scheduledDate: when,
        notificationDetails: _details,
        androidScheduleMode: mode,
        payload: n.id,
      );
    } catch (e) {
      debugPrint('Could not schedule reminder: $e');
    }
  }

  /// Windows: a timer that shows the toast when it elapses.
  void _arm(Note n, int id, DateTime at) {
    _timers.remove(id)?.cancel();
    var delay = at.difference(DateTime.now());
    if (delay.isNegative) delay = Duration.zero;
    // Very long timers are re-armed by the next reschedule (every change and
    // every app start), so cap them to keep things robust across sleep.
    if (delay > const Duration(hours: 6)) return;
    _timers[id] = Timer(delay, () async {
      _timers.remove(id);
      final store = _store;
      final current = store?.byId(n.id);
      if (current == null || _target(current) != at) return; // changed since
      await _show(current, id);
    });
  }

  Future<void> _show(Note n, int id, {bool overdue = false}) async {
    try {
      await _plugin.show(
        id: id,
        title: _title(n),
        body: _body(n, overdue: overdue),
        notificationDetails: _details,
        payload: n.id,
      );
    } catch (e) {
      debugPrint('Could not show reminder: $e');
    }
  }

  /// Windows re-checks hourly so long timers and sleep/wake stay accurate.
  Timer? _tick;
  void startTick() {
    if (_osScheduler) return;
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(minutes: 30), (_) {
      final s = _store;
      if (s != null) reschedule(s);
    });
  }
}
