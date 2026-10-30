import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'models.dart';
import 'nlp.dart';
import 'settings.dart';
import 'store.dart';

/// Turns things sent to Inkwell into notes: text or files shared from other
/// Android apps, and files dropped onto the Windows window.
class ShareIntake {
  ShareIntake(this.store, this.settings);

  final NoteStore store;
  final AppSettings settings;

  /// Id of the note just created; the UI opens it and clears the value.
  final ValueNotifier<String?> openNote = ValueNotifier<String?>(null);

  /// Notes about files that could not be added (too large, unreadable).
  final ValueNotifier<String?> warning = ValueNotifier<String?>(null);

  static const MethodChannel _channel = MethodChannel('inkwell/share');

  /// Starts listening for shares (Android). Safe to call on other platforms.
  /// The native side is a small handler in MainActivity (added by
  /// tool/bootstrap.dart) that copies shared content into the app's cache.
  Future<void> start() async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') await _handle(call.arguments);
      return null;
    });
    try {
      await _handle(await _channel.invokeMethod<Object?>('getInitial'));
    } catch (e) {
      debugPrint('Sharing is unavailable: $e');
    }
  }

  void dispose() {
    openNote.dispose();
    warning.dispose();
  }

  Future<void> _handle(Object? data) async {
    if (data is! Map) return;
    final text = (data['text'] as String?) ?? '';
    final files = <File>[
      for (final path in (data['files'] as List?) ?? const [])
        if (path is String && path.isNotEmpty) File(path),
    ];
    await createNoteFrom(text: text, files: files);
  }

  /// Creates a note from shared [text] and/or [files] and asks the UI to
  /// open it. Returns null when there was nothing usable.
  Future<Note?> createNoteFrom({String? text, List<File> files = const []}) async {
    final body = (text ?? '').trim();
    if (body.isEmpty && files.isEmpty) return null;

    String title;
    String rest = '';
    if (body.isNotEmpty) {
      final lines = body.split('\n');
      title = lines.first.trim();
      if (title.length > 80) title = '${title.substring(0, 77)}…';
      rest = lines.length > 1 ? lines.skip(1).join('\n').trim() : '';
      // A long single paragraph keeps its full text in the body.
      if (rest.isEmpty && lines.first.trim().length > 80) rest = body;
    } else {
      title = files.length == 1
          ? p.basenameWithoutExtension(files.first.path)
          : '${files.length} shared files';
    }

    var note = await store.createFromEntry(
      ParsedEntry(title: title, body: rest),
    );

    final skipped = <String>[];
    final refs = <AttachmentRef>[];
    for (final f in files) {
      final name = p.basename(f.path);
      try {
        if (!await f.exists()) continue;
        final r = await store.importAttachment(f, name,
            level: settings.imageCompression);
        refs.add(r.ref);
      } on AttachmentTooLarge catch (e) {
        skipped.add('$name: $e');
      } catch (e) {
        skipped.add('$name: $e');
      }
    }
    if (refs.isNotEmpty) {
      final cur = store.byId(note.id) ?? note;
      final seen = <String>{};
      note = cur.copyWith(
        attachments: [for (final r in refs) if (seen.add(r.hash)) r],
        updatedAt: DateTime.now().toUtc(),
      );
      await store.save(note);
    }
    if (skipped.isNotEmpty) warning.value = skipped.join('\n');
    openNote.value = note.id;
    return note;
  }
}
