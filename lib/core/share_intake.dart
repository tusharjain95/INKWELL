import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

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

  StreamSubscription<List<SharedMediaFile>>? _sub;

  /// Starts listening for shares (Android). Safe to call on other platforms.
  Future<void> start() async {
    if (!Platform.isAndroid) return;
    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isNotEmpty) await _handle(initial);
      ReceiveSharingIntent.instance.reset();
      _sub = ReceiveSharingIntent.instance.getMediaStream().listen(
        (items) async {
          await _handle(items);
          ReceiveSharingIntent.instance.reset();
        },
        onError: (Object e) => debugPrint('Share receive error: $e'),
      );
    } catch (e) {
      debugPrint('Sharing is unavailable: $e');
    }
  }

  void dispose() {
    _sub?.cancel();
    openNote.dispose();
    warning.dispose();
  }

  Future<void> _handle(List<SharedMediaFile> items) async {
    final texts = <String>[];
    final files = <File>[];
    for (final it in items) {
      if (it.type == SharedMediaType.text || it.type == SharedMediaType.url) {
        if (it.path.trim().isNotEmpty) texts.add(it.path.trim());
      } else if (it.path.isNotEmpty) {
        files.add(File(it.path));
      }
    }
    final text = [
      ...texts,
      for (final it in items)
        if (it.message != null && it.message!.trim().isNotEmpty &&
            it.type != SharedMediaType.text && it.type != SharedMediaType.url)
          it.message!.trim(),
    ].join('\n\n');
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
