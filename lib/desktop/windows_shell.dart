import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../core/reminders.dart';
import '../core/settings.dart';
import '../sync/sync_service.dart';

/// Arguments Windows passes when it starts Inkwell at sign-in.
const String kMinimizedArg = '--minimized';

/// Windows desktop integration: system tray icon, "close to tray" (so sync and
/// reminders keep working), start with Windows, and a single running copy.
class WindowsShell with TrayListener, WindowListener {
  WindowsShell._(this._root, this._lock);

  final Directory _root;
  final RandomAccessFile _lock;
  late AppSettings _settings;
  late SyncService _sync;
  Timer? _signalPoll;
  bool _quitting = false;
  bool _lastStartup = false;

  File get _signal => File(p.join(_root.path, 'show.signal'));

  /// Takes the single-instance lock. Returns null when Inkwell is already
  /// running; in that case the running copy is asked to show its window.
  static Future<WindowsShell?> acquire(Directory root, {required bool minimized}) async {
    final lockFile = File(p.join(root.path, 'instance.lock'));
    try {
      await root.create(recursive: true);
      final raf = await lockFile.open(mode: FileMode.write);
      await raf.lock(FileLock.exclusive);
      return WindowsShell._(root, raf);
    } on FileSystemException {
      if (!minimized) {
        try {
          await File(p.join(root.path, 'show.signal'))
              .writeAsString(DateTime.now().toIso8601String());
        } catch (_) {}
      }
      return null;
    }
  }

  /// Sets up the window, tray and startup entry. Call after the services exist
  /// and before runApp.
  Future<void> init({
    required AppSettings settings,
    required SyncService sync,
    required ReminderService reminders,
    required bool startHidden,
  }) async {
    _settings = settings;
    _sync = sync;

    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1100, 760),
        minimumSize: Size(420, 520),
        title: 'Inkwell',
        titleBarStyle: TitleBarStyle.normal,
      ),
      () async {
        if (startHidden && settings.keepInTray) {
          await windowManager.hide();
        } else {
          await windowManager.show();
          await windowManager.focus();
        }
      },
    );
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip('Inkwell');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'open', label: 'Open Inkwell'),
        MenuItem(key: 'sync', label: 'Sync now'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit'),
      ]));
      trayManager.addListener(this);
    } catch (e) {
      debugPrint('Tray unavailable: $e');
    }

    // Start with Windows.
    try {
      launchAtStartup.setup(
        appName: 'Inkwell',
        appPath: Platform.resolvedExecutable,
        args: const [kMinimizedArg],
      );
      _lastStartup = settings.startWithWindows;
      await _applyStartup();
    } catch (e) {
      debugPrint('Start with Windows unavailable: $e');
    }
    settings.addListener(_onSettings);

    // A second launch, or a tapped reminder, brings the window forward.
    _signalPoll = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (await _signal.exists()) {
        try {
          await _signal.delete();
        } catch (_) {}
        await showWindow();
      }
    });
    reminders.openNote.addListener(() {
      if (reminders.openNote.value != null) showWindow();
    });
  }

  Future<void> _applyStartup() async {
    final want = _settings.startWithWindows;
    final have = await launchAtStartup.isEnabled();
    if (want && !have) await launchAtStartup.enable();
    if (!want && have) await launchAtStartup.disable();
  }

  void _onSettings() {
    if (_settings.startWithWindows != _lastStartup) {
      _lastStartup = _settings.startWithWindows;
      unawaited(_applyStartup());
    }
  }

  Future<void> showWindow() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    if (_quitting) return;
    _quitting = true;
    _signalPoll?.cancel();
    try {
      await _sync.syncNow().timeout(const Duration(seconds: 20));
    } catch (_) {}
    try {
      await trayManager.destroy();
    } catch (_) {}
    try {
      await _lock.unlock();
      await _lock.close();
    } catch (_) {}
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  // ------------------------------------------------------------ WindowListener

  @override
  void onWindowClose() {
    if (_settings.keepInTray && !_quitting) {
      windowManager.hide();
      // Push anything just edited while the user could still be watching.
      _sync.maybeAutoSync();
    } else {
      quit();
    }
  }

  // -------------------------------------------------------------- TrayListener

  @override
  void onTrayIconMouseDown() => showWindow();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        showWindow();
      case 'sync':
        _sync.syncNow();
      case 'quit':
        quit();
    }
  }
}
