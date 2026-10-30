import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/reminders.dart';
import 'desktop/windows_shell.dart';
import 'core/settings.dart';
import 'core/share_intake.dart';
import 'core/speech.dart';
import 'core/store.dart';
import 'sync/background_sync.dart';
import 'sync/sync_service.dart';
import 'sync/update_service.dart';
import 'sync/worker_guard.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundSync.init();

  // Windows: only one copy may run; a second launch just shows the first.
  WindowsShell? shell;
  final minimized = args.contains(kMinimizedArg);
  if (Platform.isWindows) {
    shell = await WindowsShell.acquire(await NoteStore.defaultRoot(),
        minimized: minimized);
    if (shell == null) exit(0);
  }

  // A background sync may be mid-write; wait for it before reading notes.
  final root = await NoteStore.defaultRoot();
  final guard = WorkerGuard(root);
  await guard.markActive();
  await guard.waitForRelease();

  final store = await NoteStore.open();
  final settings = await AppSettings.load();
  final sync = SyncService(store, settings, guard: guard);
  final voice = VoiceInput(settings);
  final intake = ShareIntake(store, settings);
  unawaited(intake.start());
  final reminders = ReminderService(settings);
  await reminders.init();
  reminders.attach(store);
  reminders.startTick();

  if (shell != null) {
    await shell.init(
      settings: settings,
      sync: sync,
      reminders: reminders,
      startHidden: minimized,
    );
  }

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<NoteStore>.value(value: store),
        ChangeNotifierProvider<AppSettings>.value(value: settings),
        ChangeNotifierProvider<SyncService>.value(value: sync),
        ChangeNotifierProvider<VoiceInput>.value(value: voice),
        Provider<WorkerGuard>.value(value: guard),
        Provider<ReminderService>.value(value: reminders),
        Provider<ShareIntake>.value(value: intake),
        Provider<UpdateService>(create: (_) => UpdateService()),
      ],
      child: const InkwellApp(),
    ),
  );
}
