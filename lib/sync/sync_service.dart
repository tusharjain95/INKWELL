import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

import '../core/crypto.dart';
import '../core/merge.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/store.dart';
import 'github_client.dart';
import 'worker_guard.dart';

const String _metaPath = 'inkwell/meta.json';
const String _notesPrefix = 'inkwell/notes/';
const String _blobsPrefix = 'inkwell/blobs/';

class SyncException implements Exception {
  SyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

class SyncReport {
  const SyncReport({
    this.pulled = 0,
    this.pushed = 0,
    this.uploads = 0,
    this.conflicts = 0,
    this.upToDate = false,
    this.removed = 0,
  });

  final int pulled;
  final int pushed;
  final int uploads;
  final int conflicts;
  final bool upToDate;

  /// Abandoned attachments deleted from the repository.
  final int removed;

  String describe() {
    if (upToDate || (pulled == 0 && pushed == 0 && uploads == 0 && removed == 0)) {
      return 'Everything is up to date.';
    }
    final parts = <String>[
      if (pulled > 0) '$pulled downloaded',
      if (pushed > 0) '$pushed uploaded',
      if (uploads > 0) '$uploads attachment${uploads == 1 ? '' : 's'}',
      if (removed > 0) '$removed unused attachment${removed == 1 ? '' : 's'} removed',
      if (conflicts > 0)
        '$conflicts conflict${conflicts == 1 ? '' : 's'} (both versions kept)',
    ];
    return parts.join(' · ');
  }
}

/// How long an unused attachment stays in the repository before it is deleted.
const Duration _orphanGrace = Duration(days: 14);

/// Syncs the local [NoteStore] with a private GitHub repository.
///
/// Repository layout (everything is AES-256-GCM encrypted except meta.json):
///   inkwell/meta.json              salt + passphrase check
///   inkwell/notes/`<id>`.enc         one file per note
///   inkwell/blobs/`<keyed-hash>`.enc one file per attachment
class SyncService extends ChangeNotifier {
  SyncService(this.store, this.settings, {this.guard});

  final NoteStore store;
  final AppSettings settings;

  /// Shared with the Android background worker so a foreground sync and a
  /// background sync never run at the same time.
  final WorkerGuard? guard;

  bool running = false;
  String? lastError;
  String? lastMessage;

  Vault? _vault;
  String? _vaultMetaSha;
  String? _vaultPass;

  Timer? _debounce;
  Timer? _periodic;

  DateTime? get lastSyncAt => store.state.lastSyncAt == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(store.state.lastSyncAt!);

  bool get configured => settings.config.isComplete;

  void start() {
    store.addListener(_onStoreChanged);
    _periodic?.cancel();
    _periodic =
        Timer.periodic(const Duration(minutes: 5), (_) => maybeAutoSync());
  }

  @override
  void dispose() {
    store.removeListener(_onStoreChanged);
    _debounce?.cancel();
    _periodic?.cancel();
    super.dispose();
  }

  int _followUps = 0;

  void _onStoreChanged() {
    if (running || store.state.dirty.isEmpty) return;
    if (!settings.autoSync || !configured) return;
    _followUps = 0;
    _debounce?.cancel();
    // Short, so a tick or quick edit reaches the other device before you pick
    // it up. Typing keeps pushing the timer back until you pause.
    _debounce = Timer(const Duration(seconds: 4), maybeAutoSync);
  }

  /// A change made while a sync was uploading is left dirty by that sync;
  /// run again shortly so it is not stranded until the next edit.
  void _followUpIfDirty() {
    if (lastError != null || store.state.dirty.isEmpty) return;
    if (!settings.autoSync || !configured || _followUps >= 2) return;
    _followUps++;
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 3), maybeAutoSync);
  }

  Future<void> maybeAutoSync() async {
    if (!settings.autoSync || !configured || running) return;
    await syncNow();
  }

  GitHubClient _client(SyncConfig c) =>
      GitHubClient(token: c.token, repo: c.repo, branch: c.branch);

  // ------------------------------------------------------------ verification

  /// Checks a configuration without changing anything. Returns a short
  /// human-readable result, or throws with the reason it failed.
  Future<String> verify(SyncConfig cfg) async {
    final gh = _client(cfg);
    if (!await gh.isPrivate()) {
      throw SyncException(
          'This repository is public. Create a private repository for sync.');
    }
    final head = await gh.headSha();
    if (head == null) {
      throw SyncException(
          'Branch "${cfg.branch}" has no commits yet. Create the repository with a README, or check the branch name.');
    }
    final tree = await gh.listTree(await gh.treeShaOfCommit(head));
    final metaSha = tree[_metaPath];
    if (metaSha == null) {
      return 'Connected. This repository is empty, so your first sync will set it up with this passphrase.';
    }
    await _vaultFor(gh, cfg.passphrase, metaSha: metaSha);
    return 'Connected. Passphrase verified against existing data.';
  }

  // -------------------------------------------------------------------- sync

  Future<SyncReport?> syncNow() async {
    if (running) return null;
    final cfg = settings.config;
    if (!cfg.isComplete) {
      lastError = 'Set up GitHub sync in Settings first.';
      notifyListeners();
      return null;
    }
    running = true;
    lastError = null;
    notifyListeners();
    var locked = false;
    try {
      final g = guard;
      if (g != null) {
        locked = await g.tryAcquire();
        if (!locked) {
          lastMessage = 'Another sync is already running.';
          return null;
        }
      }
      SyncReport? report;
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          report = await _syncOnce(cfg);
          break;
        } on RefConflictException {
          _vault = null; // another device may have just created meta.json
          if (attempt == 3) {
            throw GitHubException(
                'Another device kept changing the repository. Try again in a moment.');
          }
        }
      }
      final done = report ?? const SyncReport(upToDate: true);
      store.state.lastSyncAt = DateTime.now().millisecondsSinceEpoch;
      await store.saveState();
      lastMessage = done.describe();
      return done;
    } on GitHubException catch (e) {
      lastError = e.message;
    } on SyncException catch (e) {
      lastError = e.message;
    } on CryptoException catch (e) {
      lastError = e.message;
    } catch (e) {
      lastError = 'Sync failed: $e';
    } finally {
      if (locked) await guard?.release();
      running = false;
      notifyListeners();
      _followUpIfDirty();
    }
    return null;
  }

  Future<SyncReport> _syncOnce(SyncConfig cfg) async {
    final gh = _client(cfg);
    final state = store.state;

    final head = await gh.headSha();
    if (head == null) {
      throw SyncException(
          'Branch "${cfg.branch}" has no commits yet. Create the repository with a README, or check the branch name.');
    }
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final cleanupDue = state.orphanSince.values
        .any((t) => nowMs - t >= _orphanGrace.inMilliseconds);
    if (head == state.lastHead && state.dirty.isEmpty && !cleanupDue) {
      return const SyncReport(upToDate: true);
    }

    final treeSha = await gh.treeShaOfCommit(head);
    final tree = await gh.listTree(treeSha);

    final remoteNotes = <String, String>{}; // id -> blob sha
    final remoteBlobs = <String, String>{}; // keyed name -> blob sha
    tree.forEach((path, sha) {
      if (path.startsWith(_notesPrefix) && path.endsWith('.enc')) {
        remoteNotes[path.substring(_notesPrefix.length, path.length - 4)] = sha;
      } else if (path.startsWith(_blobsPrefix) && path.endsWith('.enc')) {
        remoteBlobs[path.substring(_blobsPrefix.length, path.length - 4)] = sha;
      }
    });

    final entries = <TreeEntry>[];
    final vault = await _vaultFor(
      gh,
      cfg.passphrase,
      metaSha: tree[_metaPath],
      onCreate: (metaBytes) async {
        final sha = await gh.createBlob(metaBytes);
        entries.add(TreeEntry(_metaPath, sha));
        return sha;
      },
    );

    // ---- pull: decide per note ------------------------------------------
    final local = {for (final n in store.all) n.id: n};
    final ids = {...local.keys, ...remoteNotes.keys};
    var pulled = 0;
    var conflicts = 0;

    for (final id in ids) {
      final l = local[id];
      final rSha = remoteNotes[id];
      final remoteChanged = rSha != null && rSha != state.noteShas[id];
      Note? r;
      if (remoteChanged) {
        final clear = await vault.decrypt(await gh.getBlob(rSha));
        r = Note.fromJson(jsonDecode(utf8.decode(clear)) as Map<String, dynamic>);
      }
      switch (decide(
        local: l,
        remote: r,
        dirty: state.dirty.contains(id),
        remoteChanged: remoteChanged,
      )) {
        case MergeAction.none:
          break;
        case MergeAction.takeRemote:
          await store.applyRemote(r!);
          state.noteShas[id] = rSha!;
          state.dirty.remove(id);
          pulled++;
        case MergeAction.pushLocal:
          state.dirty.add(id);
        case MergeAction.conflictKeepRemote:
          await store.saveConflictCopy(l!);
          await store.applyRemote(r!);
          state.noteShas[id] = rSha!;
          state.dirty.remove(id);
          conflicts++;
          pulled++;
        case MergeAction.conflictKeepLocal:
          await store.saveConflictCopy(r!);
          state.noteShas[id] = rSha!; // remote version is now "seen"
          state.dirty.add(id);
          conflicts++;
      }
    }
    state.dirty.removeWhere((id) => store.byId(id) == null);
    await store.saveState();

    // ---- push: encrypt and upload everything dirty -----------------------
    final pushIds = state.dirty.toList();
    final pushedAt = <String, int>{};
    final newNoteShas = <String, String>{};

    for (final id in pushIds) {
      final n = store.byId(id)!;
      pushedAt[id] = n.updatedAt.millisecondsSinceEpoch;
      final enc = await vault.encrypt(utf8.encode(jsonEncode(n.toJson())));
      final sha = await gh.createBlob(enc);
      entries.add(TreeEntry('$_notesPrefix$id.enc', sha));
      newNoteShas[id] = sha;
    }

    final uploadedBlobs = <String, String>{};
    for (final id in pushIds) {
      for (final a in store.byId(id)!.attachments) {
        final name = await vault.blobName(a.hash);
        if (remoteBlobs.containsKey(name) || uploadedBlobs.containsKey(name)) {
          continue;
        }
        final file = store.blobFile(a.hash);
        if (!await file.exists()) continue; // not downloaded on this device
        final enc = await vault.encrypt(await file.readAsBytes());
        final sha = await gh.createBlob(enc);
        uploadedBlobs[name] = sha;
        entries.add(TreeEntry('$_blobsPrefix$name.enc', sha));
      }
    }

    // Repair: a note that is already synced but whose attachment is missing
    // from the repository (for example it was lost or removed) is re-uploaded
    // from this device when we still have the file.
    final names = <String, String>{};
    Future<String> nameFor(String hash) async =>
        names[hash] ??= await vault.blobName(hash);
    for (final n in store.all) {
      if (state.dirty.contains(n.id)) continue;
      for (final a in n.attachments) {
        final name = await nameFor(a.hash);
        if (remoteBlobs.containsKey(name) || uploadedBlobs.containsKey(name)) {
          continue;
        }
        final file = store.blobFile(a.hash);
        if (!await file.exists()) continue;
        final enc = await vault.encrypt(await file.readAsBytes());
        final sha = await gh.createBlob(enc);
        uploadedBlobs[name] = sha;
        entries.add(TreeEntry('$_blobsPrefix$name.enc', sha));
      }
    }

    // Clean up: attachments no note uses any more (removed from a note, or
    // the note was emptied from the trash) are deleted from the repository
    // after a grace period, so a device that was offline can still sync its
    // own changes. Git history keeps old versions; this only trims the
    // current tree.
    final referenced = <String>{};
    for (final n in store.all) {
      for (final a in n.attachments) {
        referenced.add(await nameFor(a.hash));
      }
    }
    state.orphanSince.removeWhere(
        (name, _) => referenced.contains(name) || !remoteBlobs.containsKey(name));
    final removedNames = <String>[];
    for (final name in remoteBlobs.keys) {
      if (referenced.contains(name) || uploadedBlobs.containsKey(name)) continue;
      final since = state.orphanSince.putIfAbsent(name, () => nowMs);
      if (nowMs - since >= _orphanGrace.inMilliseconds) {
        entries.add(TreeEntry.delete('$_blobsPrefix$name.enc'));
        removedNames.add(name);
      }
    }

    var newHead = head;
    if (entries.isNotEmpty) {
      final newTree = await gh.createTree(treeSha, entries);
      final msg = 'Inkwell sync from ${_deviceName()}'
          '${pushIds.isEmpty ? '' : ' · ${pushIds.length} note(s)'}';
      final commit = await gh.createCommit(msg, newTree, head);
      await gh.updateRef(commit);
      newHead = commit;
    }

    // ---- bookkeeping -----------------------------------------------------
    for (final e in newNoteShas.entries) {
      state.noteShas[e.key] = e.value;
      final current = store.byId(e.key);
      // Edited again while we were uploading? Leave it dirty for next time.
      if (current != null &&
          current.updatedAt.millisecondsSinceEpoch == pushedAt[e.key]) {
        state.dirty.remove(e.key);
      }
    }
    state.blobShas
      ..clear()
      ..addAll(remoteBlobs)
      ..addAll(uploadedBlobs);
    for (final name in removedNames) {
      state.blobShas.remove(name);
      state.orphanSince.remove(name);
    }
    state.lastHead = newHead;
    await store.saveState();

    return SyncReport(
      pulled: pulled,
      pushed: pushIds.length,
      uploads: uploadedBlobs.length,
      conflicts: conflicts,
      removed: removedNames.length,
    );
  }

  // ------------------------------------------------------------ attachments

  /// Returns the local file for an attachment, downloading and decrypting it
  /// from the repository first if this device does not have it yet.
  Future<File> ensureAttachment(AttachmentRef ref) async {
    final local = store.blobFile(ref.hash);
    if (await local.exists()) return local;

    final cfg = settings.config;
    if (!cfg.isComplete) {
      throw SyncException(
          'This attachment is not on this device yet. Set up sync to download it.');
    }
    final gh = _client(cfg);
    final head = await gh.headSha();
    if (head == null) throw SyncException('The sync branch is empty.');
    final tree = await gh.listTree(await gh.treeShaOfCommit(head));
    final metaSha = tree[_metaPath];
    if (metaSha == null) throw SyncException('No synced data in the repository.');

    final vault = await _vaultFor(gh, cfg.passphrase, metaSha: metaSha);
    final name = await vault.blobName(ref.hash);
    final sha = tree['$_blobsPrefix$name.enc'];
    if (sha == null) {
      throw SyncException(
          'The attachment has not been uploaded yet. Sync the device that added it.');
    }
    final bytes = await vault.decrypt(await gh.getBlob(sha));
    final actual = toHex((await Sha256().hash(bytes)).bytes);
    if (actual != ref.hash) {
      throw SyncException('Downloaded attachment failed its integrity check.');
    }
    await store.storeBlob(ref.hash, Uint8List.fromList(bytes));
    return local;
  }

  // ------------------------------------------------------------------ vault

  Future<Vault> _vaultFor(
    GitHubClient gh,
    String passphrase, {
    String? metaSha,
    Future<String> Function(Uint8List metaBytes)? onCreate,
  }) async {
    if (metaSha == null) {
      if (onCreate == null) {
        throw SyncException('This repository has no Inkwell data yet.');
      }
      final salt = Vault.randomSalt();
      final vault = await Vault.derive(passphrase, salt);
      final meta = {
        'v': 1,
        'kdf': 'pbkdf2-sha256',
        'iter': kKdfIterations,
        'salt': base64Encode(salt),
        'check': base64Encode(await vault.makeCheck()),
      };
      final sha =
          await onCreate(Uint8List.fromList(utf8.encode(jsonEncode(meta))));
      _vault = vault;
      _vaultMetaSha = sha;
      _vaultPass = passphrase;
      return vault;
    }

    if (_vault != null && _vaultMetaSha == metaSha && _vaultPass == passphrase) {
      return _vault!;
    }
    final raw = await gh.getBlob(metaSha);
    final meta = jsonDecode(utf8.decode(raw)) as Map<String, dynamic>;
    final vault = await Vault.derive(
      passphrase,
      Uint8List.fromList(base64Decode(meta['salt'] as String)),
      iterations: (meta['iter'] as num?)?.toInt() ?? kKdfIterations,
    );
    await vault.verifyCheck(base64Decode(meta['check'] as String));
    _vault = vault;
    _vaultMetaSha = metaSha;
    _vaultPass = passphrase;
    return vault;
  }

  String _deviceName() {
    try {
      return Platform.localHostname;
    } catch (_) {
      return 'device';
    }
  }
}
