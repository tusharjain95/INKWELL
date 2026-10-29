import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'core/settings.dart';
import 'core/speech.dart';
import 'core/store.dart';
import 'sync/background_sync.dart';
import 'sync/sync_service.dart';
import 'sync/update_service.dart';
import 'sync/worker_guard.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await BackgroundSync.init();

  // A background sync may be mid-write; wait for it before reading notes.
  final root = await NoteStore.defaultRoot();
  final guard = WorkerGuard(root);
  await guard.markActive();
  await guard.waitForRelease();

  final store = await NoteStore.open();
  final settings = await AppSettings.load();
  final sync = SyncService(store, settings, guard: guard);
  final voice = VoiceInput(settings);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<NoteStore>.value(value: store),
        ChangeNotifierProvider<AppSettings>.value(value: settings),
        ChangeNotifierProvider<SyncService>.value(value: sync),
        ChangeNotifierProvider<VoiceInput>.value(value: voice),
        Provider<WorkerGuard>.value(value: guard),
        Provider<UpdateService>(create: (_) => UpdateService()),
      ],
      child: const InkwellApp(),
    ),
  );
}
