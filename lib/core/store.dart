import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'crypto.dart' show toHex;
import 'image_compress.dart';
import 'models.dart';
import 'nlp.dart';

class AttachmentTooLarge implements Exception {
  AttachmentTooLarge(this.bytes);
  final int bytes;
  @override
  String toString() =>
      'File is ${(bytes / 1048576).toStringAsFixed(1)} MB; the limit is '
      '${kMaxAttachmentBytes ~/ 1048576} MB.';
}

/// Result of attaching a file: the reference to store in the note plus what
/// compression did, so the UI can say "4.2 MB -> 610 KB".
class ImportedAttachment {
  const ImportedAttachment(this.ref, this.originalSize);

  final AttachmentRef ref;
  final int originalSize;

  bool get wasCompressed => ref.size < originalSize;
  int get savedBytes => originalSize - ref.size;
}

/// Which slice of the library the list shows.
enum NoteView { all, tasks, today }

/// Bookkeeping the sync engine needs between runs.
class SyncState {
  SyncState({
    this.lastHead,
    Map<String, String>? noteShas,
    Map<String, String>? blobShas,
    Set<String>? dirty,
    this.lastSyncAt,
    Map<String, int>? orphanSince,
  })  : noteShas = noteShas ?? {},
        blobShas = blobShas ?? {},
        dirty = dirty ?? {},
        orphanSince = orphanSince ?? {};

  /// Commit we last synced against.
  String? lastHead;

  /// Note id -> git blob sha of the version last synced (the merge baseline).
  final Map<String, String> noteShas;

  /// Remote attachment name -> git blob sha, from the last tree listing.
  final Map<String, String> blobShas;

  /// Notes edited locally since their last successful push.
  final Set<String> dirty;
  int? lastSyncAt;

  /// Remote attachment name -> when sync first saw that no note uses it.
  /// Used to delete abandoned attachments after a grace period.
  final Map<String, int> orphanSince;

  Map<String, dynamic> toJson() => {
        'lastHead': lastHead,
        'noteShas': noteShas,
        'blobShas': blobShas,
        'dirty': dirty.toList(),
        'lastSyncAt': lastSyncAt,
        'orphanSince': orphanSince,
      };

  factory SyncState.fromJson(Map<String, dynamic> j) => SyncState(
        lastHead: j['lastHead'] as String?,
        noteShas: ((j['noteShas'] as Map?) ?? const {}).cast<String, String>(),
        blobShas: ((j['blobShas'] as Map?) ?? const {}).cast<String, String>(),
        dirty: ((j['dirty'] as List?) ?? const []).cast<String>().toSet(),
        lastSyncAt: (j['lastSyncAt'] as num?)?.toInt(),
        orphanSince: (((j['orphanSince'] as Map?) ?? const {}).cast<String, num>())
            .map((k, v) => MapEntry(k, v.toInt())),
      );
}

/// Local, offline-first storage. One JSON file per note plus a
/// content-addressed folder of attachments. No database engine, so there is
/// nothing to migrate and nothing heavy to start.
class NoteStore extends ChangeNotifier {
  NoteStore._(this.root);

  final Directory root;
  final Map<String, Note> _notes = {};
  SyncState state = SyncState();

  Directory get _notesDir => Directory(p.join(root.path, 'notes'));
  Directory get _blobsDir => Directory(p.join(root.path, 'blobs'));
  File get _stateFile => File(p.join(root.path, 'sync_state.json'));

  /// Where notes live. The Android background worker resolves the same path.
  static Future<Directory> defaultRoot() async => Directory(
      p.join((await getApplicationSupportDirectory()).path, 'inkwell'));

  static Future<NoteStore> open({Directory? rootOverride}) async {
    final base = rootOverride ?? await defaultRoot();
    final store = NoteStore._(base);
    await store._load();
    return store;
  }

  Future<void> _load() async {
    // Read everything first, then swap in one step: clearing up front would
    // leave a moment with no notes, and open editors would be torn down.
    final loaded = <String, Note>{};
    await _notesDir.create(recursive: true);
    await _blobsDir.create(recursive: true);
    await for (final e in _notesDir.list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      try {
        final j = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
        final n = Note.fromJson(j);
        loaded[n.id] = n;
      } catch (_) {
        // A corrupt file must never stop the app from opening.
      }
    }
    // Disk wins (a background worker may have changed it), except for a note
    // saved in memory a moment ago whose file was not written yet.
    for (final e in _notes.entries) {
      final onDisk = loaded[e.key];
      if (onDisk == null || e.value.updatedAt.isAfter(onDisk.updatedAt)) {
        loaded[e.key] = e.value;
      }
    }
    _notes
      ..clear()
      ..addAll(loaded);
    if (await _stateFile.exists()) {
      try {
        state = SyncState.fromJson(
            jsonDecode(await _stateFile.readAsString()) as Map<String, dynamic>);
      } catch (_) {
        state = SyncState();
      }
    }
    unawaited(_gcBlobs());
  }

  /// Re-reads everything from disk. Used when the app returns to the
  /// foreground, because the background sync worker may have changed files
  /// while this process held an older copy in memory.
  Future<void> reload() async {
    await _load();
    notifyListeners();
  }

  // ---------------------------------------------------------------- queries

  /// Every note including tombstones. Used by sync.
  List<Note> get all => _notes.values.toList();

  Note? byId(String id) => _notes[id];

  int get trashCount => _notes.values.where((n) => n.deleted && !n.isBlank).length;

  Set<String> get allTags => {
        for (final n in _notes.values)
          if (!n.deleted) ...n.tags,
      };

  int get openTaskCount =>
      _notes.values.where((n) => !n.deleted && n.isTask && !n.done).length;

  int get dueTodayCount {
    final cutoff = _startOfTomorrow();
    return _notes.values
        .where((n) =>
            !n.deleted && n.isTask && !n.done && n.due != null && n.due!.isBefore(cutoff))
        .length;
  }

  DateTime _startOfTomorrow() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + 1);
  }

  List<Note> query({
    String search = '',
    String? tag,
    bool trash = false,
    NoteView view = NoteView.all,
  }) {
    final q = search.trim().toLowerCase();
    final cutoff = _startOfTomorrow();
    final out = _notes.values.where((n) {
      if (n.deleted != trash) return false;
      if (trash && n.isBlank) return false;
      if (!trash) {
        if (view == NoteView.tasks && !n.isTask) return false;
        if (view == NoteView.today) {
          if (!n.isTask || n.done || n.due == null || !n.due!.isBefore(cutoff)) {
            return false;
          }
        }
      }
      if (tag != null && !n.tags.contains(tag)) return false;
      if (q.isEmpty) return true;
      return n.title.toLowerCase().contains(q) ||
          n.plain.toLowerCase().contains(q) ||
          n.tags.any((t) => t.toLowerCase().contains(q)) ||
          n.attachments.any((a) => a.name.toLowerCase().contains(q));
    }).toList();

    if (view == NoteView.all || trash) {
      out.sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return b.updatedAt.compareTo(a.updatedAt);
      });
    } else {
      // Task views: open tasks first, soonest due first, then by priority.
      out.sort((a, b) {
        if (a.done != b.done) return a.done ? 1 : -1;
        final ad = a.due, bd = b.due;
        if (ad != null && bd != null) {
          final c = ad.compareTo(bd);
          if (c != 0) return c;
        } else if (ad != null) {
          return -1;
        } else if (bd != null) {
          return 1;
        }
        final ap = a.priority == 0 ? 9 : a.priority;
        final bp = b.priority == 0 ? 9 : b.priority;
        if (ap != bp) return ap.compareTo(bp);
        return b.updatedAt.compareTo(a.updatedAt);
      });
    }
    return out;
  }

  // ----------------------------------------------------------------- writes

  Future<Note> create({bool task = false, DateTime? due}) async {
    final now = DateTime.now().toUtc();
    final n = Note(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      isTask: task,
      due: task ? due : null,
    );
    await save(n);
    return n;
  }

  /// Persists a local edit and marks the note for the next sync.
  Future<void> save(Note n) async {
    _notes[n.id] = n;
    await _writeAtomic(File(p.join(_notesDir.path, '${n.id}.json')),
        jsonEncode(n.toJson()));
    if (state.dirty.add(n.id)) await saveState();
    notifyListeners();
  }

  /// Stores a note that arrived from the remote. Not marked dirty.
  Future<void> applyRemote(Note n) async {
    _notes[n.id] = n;
    await _writeAtomic(File(p.join(_notesDir.path, '${n.id}.json')),
        jsonEncode(n.toJson()));
    notifyListeners();
  }

  /// Keeps the losing side of a sync conflict as its own note.
  Future<void> saveConflictCopy(Note original) async {
    if (original.deleted) return;
    final now = DateTime.now().toUtc();
    final name = original.title.trim().isEmpty ? 'Untitled' : original.title;
    await save(original.copyWith(
      id: newId(),
      title: '$name (conflict copy)',
      pinned: false,
      createdAt: now,
      updatedAt: now,
    ));
  }

  /// Creates a note or task from parsed natural language (typed or dictated).
  Future<Note> createFromEntry(ParsedEntry e) async {
    final now = DateTime.now().toUtc();
    final body = e.body.isEmpty
        ? ''
        : jsonEncode([
            {'insert': '${e.body}\n'}
          ]);
    final n = Note(
      id: newId(),
      createdAt: now,
      updatedAt: now,
      title: e.title,
      body: body,
      plain: e.body,
      tags: e.tags,
      isTask: e.isTask,
      due: e.due,
      dueHasTime: e.hasTime,
      priority: e.priority,
      repeat: e.repeat,
    );
    await save(n);
    return n;
  }

  /// Ticks a task. A recurring task is not finished: it rolls forward to its
  /// next occurrence after now, so it never sits there overdue.
  Future<void> toggleDone(String id) async {
    final n = _notes[id];
    if (n == null || !n.isTask) return;
    final now = DateTime.now().toUtc();
    final rule = n.repeat;
    if (!n.done && rule != null) {
      final local = DateTime.now();
      var next = n.due ?? DateTime(local.year, local.month, local.day);
      var guard = 0;
      do {
        next = rule.next(next);
      } while (!next.isAfter(local) && ++guard < 2000);
      await save(n.copyWith(due: next, updatedAt: now));
      return;
    }
    await save(n.copyWith(done: !n.done, updatedAt: now));
  }

  Future<void> softDelete(String id) async {
    final n = _notes[id];
    if (n == null) return;
    await save(n.copyWith(deleted: true, updatedAt: DateTime.now().toUtc()));
  }

  Future<void> restore(String id) async {
    final n = _notes[id];
    if (n == null) return;
    await save(n.copyWith(deleted: false, updatedAt: DateTime.now().toUtc()));
  }

  /// Removes a note that was created but never filled in.
  Future<void> discardIfBlank(String id) async {
    final n = _notes[id];
    if (n == null || !n.isBlank || n.deleted) return;
    if (state.noteShas.containsKey(id)) {
      await softDelete(id); // already on the remote, so tombstone it
      return;
    }
    _notes.remove(id);
    state.dirty.remove(id);
    final f = File(p.join(_notesDir.path, '$id.json'));
    if (await f.exists()) await f.delete();
    await saveState();
    notifyListeners();
  }

  /// "Empty trash": drops the content of deleted notes but keeps the
  /// tombstones so other devices also stop showing them.
  Future<void> emptyTrash() async {
    for (final n in _notes.values.where((n) => n.deleted && !n.isBlank).toList()) {
      await save(n.copyWith(
        title: '',
        body: '',
        plain: '',
        tags: const [],
        attachments: const [],
        updatedAt: DateTime.now().toUtc(),
      ));
    }
  }

  /// Forget what we know about the remote and mark every note as needing an
  /// upload. Used when the sync provider changes; identical copies already on
  /// the new remote are recognised during the next sync, not duplicated.
  Future<void> resetSyncBaseline() async {
    state
      ..lastHead = null
      ..noteShas.clear()
      ..blobShas.clear()
      ..orphanSince.clear()
      ..dirty.addAll(_notes.keys);
    await saveState();
    notifyListeners();
  }

  Future<void> saveState() =>
      _writeAtomic(_stateFile, jsonEncode(state.toJson()));

  Future<void> _writeAtomic(File target, String content) async {
    final tmp = File('${target.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(target.path);
  }

  // ------------------------------------------------------------ attachments

  File blobFile(String hash) => File(p.join(_blobsDir.path, hash));

  bool hasBlob(String hash) => blobFile(hash).existsSync();

  /// Copies a picked file into the store. Photos are resized and re-encoded
  /// according to [level] (in a background isolate), and only kept in that
  /// form if that actually made them smaller.
  Future<ImportedAttachment> importAttachment(
    File src,
    String name, {
    ImageCompression level = ImageCompression.balanced,
  }) async {
    final len = await src.length();
    final mime0 = lookupMimeType(name) ?? 'application/octet-stream';
    final compressible = kCompressibleMimes.contains(mime0);
    if (len > (compressible ? kMaxImageSourceBytes : kMaxAttachmentBytes)) {
      throw AttachmentTooLarge(len);
    }

    var bytes = await src.readAsBytes();
    var mime = lookupMimeType(
          name,
          headerBytes: bytes.length > 16 ? bytes.sublist(0, 16) : bytes,
        ) ??
        'application/octet-stream';
    var finalName = name;

    if (kCompressibleMimes.contains(mime)) {
      final c = await compressImage(bytes, level: level);
      if (c != null && c.bytes.length < bytes.length * 0.9) {
        bytes = c.bytes;
        mime = c.mime;
        finalName = '${p.withoutExtension(name)}.${c.extension}';
      }
    }
    if (bytes.length > kMaxAttachmentBytes) throw AttachmentTooLarge(bytes.length);

    final hash = toHex((await Sha256().hash(bytes)).bytes);
    final target = blobFile(hash);
    if (!await target.exists()) await target.writeAsBytes(bytes, flush: true);
    return ImportedAttachment(
      AttachmentRef(hash: hash, name: finalName, mime: mime, size: bytes.length),
      len,
    );
  }

  /// Saves an attachment downloaded from the remote.
  Future<void> storeBlob(String hash, Uint8List bytes) async {
    await blobFile(hash).writeAsBytes(bytes, flush: true);
    notifyListeners();
  }

  /// A copy of the attachment under its real file name, so the OS can pick
  /// the right app to open it with.
  Future<File> exportForOpen(AttachmentRef ref) async {
    final dir = Directory(p.join(
        (await getTemporaryDirectory()).path, 'inkwell-open', ref.hash.substring(0, 12)));
    await dir.create(recursive: true);
    final safe = ref.name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    final out = File(p.join(dir.path, safe.isEmpty ? 'file' : safe));
    if (!await out.exists()) await blobFile(ref.hash).copy(out.path);
    return out;
  }

  /// Deletes attachment files no note refers to. Files younger than a day are
  /// kept so a just-attached file is never removed before its note is saved.
  Future<void> _gcBlobs() async {
    try {
      final referenced = {
        for (final n in _notes.values)
          for (final a in n.attachments) a.hash,
      };
      final cutoff = DateTime.now().subtract(const Duration(days: 1));
      await for (final e in _blobsDir.list()) {
        if (e is! File) continue;
        if (referenced.contains(p.basename(e.path))) continue;
        if ((await e.lastModified()).isBefore(cutoff)) await e.delete();
      }
    } catch (_) {}
  }
}
