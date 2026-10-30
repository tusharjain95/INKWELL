import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';

import 'core/reminders.dart';
import 'core/settings.dart';
import 'core/store.dart';
import 'sync/background_sync.dart';
import 'sync/sync_service.dart';
import 'sync/worker_guard.dart';
import 'ui/notes_page.dart';
import 'ui/theme.dart';

class InkwellApp extends StatefulWidget {
  const InkwellApp({super.key});

  @override
  State<InkwellApp> createState() => _InkwellAppState();
}

class _InkwellAppState extends State<InkwellApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final sync = context.read<SyncService>();
    final settings = context.read<AppSettings>();
    sync.start();
    BackgroundSync.startHeartbeat(context.read<WorkerGuard>());
    _applyBackground();
    settings.addListener(_applyBackground);
    WidgetsBinding.instance.addPostFrameCallback((_) => _askNotificationPermission());
    WidgetsBinding.instance.addPostFrameCallback((_) => sync.maybeAutoSync());
  }

  /// Asks for notification permission once, the first time the app runs.
  Future<void> _askNotificationPermission() async {
    final s = context.read<AppSettings>();
    if (!s.remindersEnabled || s.getString('reminders.asked') == '1') return;
    await s.putString('reminders.asked', '1');
    if (!mounted) return;
    await context.read<ReminderService>().requestPermission();
  }

  void _applyBackground() {
    final s = context.read<AppSettings>();
    BackgroundSync.apply(
        enabled: s.backgroundSync && s.autoSync && s.syncReady);
  }

  @override
  void dispose() {
    context.read<AppSettings>().removeListener(_applyBackground);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Future<void> didChangeAppLifecycleState(AppLifecycleState state) async {
    final guard = context.read<WorkerGuard>();
    final store = context.read<NoteStore>();
    final sync = context.read<SyncService>();
    if (state == AppLifecycleState.resumed) {
      // A background run may have changed files while we were away.
      await guard.waitForRelease();
      await store.reload();
      BackgroundSync.startHeartbeat(guard);
      sync.maybeAutoSync();
    } else if (state == AppLifecycleState.paused) {
      // Push before the OS suspends us, then hand over to the worker.
      await sync.maybeAutoSync();
      await BackgroundSync.stopHeartbeat(guard);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppSettings, ThemeMode>((s) => s.themeMode);
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final light = lightDynamic ??
            ColorScheme.fromSeed(seedColor: kSeedColor, brightness: Brightness.light);
        final dark = darkDynamic ??
            ColorScheme.fromSeed(seedColor: kSeedColor, brightness: Brightness.dark);
        return MaterialApp(
          title: 'Inkwell',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: buildTheme(light),
          darkTheme: buildTheme(dark),
          localizationsDelegates: FlutterQuillLocalizations.localizationsDelegates,
          supportedLocales: FlutterQuillLocalizations.supportedLocales,
          home: const NotesPage(),
        );
      },
    );
  }
}
