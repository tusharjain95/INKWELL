import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../core/crypto.dart';
import '../core/merge.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../core/store.dart';
import 'drive_auth.dart';
import 'drive_client.dart';
import 'sync_types.dart';

const String _meta = 'meta.json';
const String _notePrefix = 'n_';
const String _blobPrefix = 'b_';
const String _ext = '.enc';

/// The Google Drive twin of the GitHub sync: the same per-note merge, the
/// same end-to-end encryption, but each file is written on its own because
/// Drive has no atomic multi-file commit.
///
/// Files live in one Drive folder named "Inkwell Sync", flat:
///   meta.json          salt + passphrase check
///   `n_<note id>.enc`    one encrypted file per note
///   `b_<keyed hash>.enc` one encrypted file per attachment
class DriveSync {
  DriveSync(this.store, this.settings, {DriveAuth? auth, String Function()? passphrase})
      : _auth = auth ?? DriveAuth(),
        _passphrase = passphrase;

  /// Lets tests supply the passphrase without secure storage.
  final String Function()? _passphrase;

  final NoteStore store;
  final AppSettings settings;
  final DriveAuth _auth;

  Vault? _vault;
  String? _vaultMd5;
  String? _vaultPass;

  DriveClient? _cachedClient;
  String? _cachedFor;

  /// One client per sign-in, so the access token and the folder id are reused
  /// instead of being looked up again on every sync.
  DriveClient _client() {
    final token = settings.driveRefreshToken;
    if (_cachedClient == null || _cachedFor != token) {
      _cachedClient = DriveClient(DriveTokenSource(_auth, token));
      _cachedFor = token;
    }
    return _cachedClient!;
  }

  /// Checks the sign-in and passphrase without changing anything.
  Future<String> verify(String passphrase, {DriveClient? client}) async {
    final c = client ?? _client();
    final byName = _byName(await c.list()).winners;
    final meta = byName[_meta];
    if (meta == null) {
      return 'Connected. Google Drive has no Inkwell data yet, so your first '
          'sync will set it up with this passphrase.';
    }
    await _deriveFromMeta(await c.download(meta.id), passphrase);
    return 'Connected. Passphrase verified against existing data.';
  }

  Future<SyncReport> syncOnce({DriveClient? client}) async {
    try {
      return await _syncOnce(client: client);
    } on DriveException {
      if (client == null) _cachedClient = null; // re-find the folder next time
      rethrow;
    }
  }

  Future<SyncReport> _syncOnce({DriveClient? client}) async {
    final c = client ?? _client();
    final state = store.state;
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    final listing = _byName(await c.list());
    final byName = listing.winners;

    final cleanupDue =
        state.orphanSince.values.any((t) => nowMs - t >= kOrphanGrace.inMilliseconds);
    final signature = await _signature(byName);
    if (signature == state.lastHead && state.dirty.isEmpty && !cleanupDue) {
      return SyncReport(
          upToDate: true,
          remoteNotes: byName.keys
              .where((n) => n.startsWith(_notePrefix) && n.endsWith(_ext))
              .length);
    }

    final remoteNotes = <String, DriveFile>{};
    final remoteBlobs = <String, DriveFile>{};
    byName.forEach((name, f) {
      if (!name.endsWith(_ext)) return;
      if (name.startsWith(_notePrefix)) {
        remoteNotes[name.substring(_notePrefix.length, name.length - _ext.length)] = f;
      } else if (name.startsWith(_blobPrefix)) {
        remoteBlobs[name.substring(_blobPrefix.length, name.length - _ext.length)] = f;
      }
    });

    final vault = await _vaultFor(c, byName[_meta]);
    var wrote = false;

    // ---- pull: decide per note -------------------------------------------
    final local = {for (final n in store.all) n.id: n};
    final ids = {...local.keys, ...remoteNotes.keys};
    var pulled = 0;
    var conflicts = 0;

    for (final id in ids) {
      final l = local[id];
      final rFile = remoteNotes[id];
      final rVersion = rFile?.md5;
      final remoteChanged = rFile != null && rVersion != state.noteShas[id];
      Note? r;
      if (remoteChanged) {
        final clear = await vault.decrypt(await c.download(rFile.id));
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
          state.noteShas[id] = rVersion!;
          state.dirty.remove(id);
          pulled++;
        case MergeAction.pushLocal:
          state.dirty.add(id);
        case MergeAction.conflictKeepRemote:
          await store.saveConflictCopy(l!);
          await store.applyRemote(r!);
          state.noteShas[id] = rVersion!;
          state.dirty.remove(id);
          conflicts++;
          pulled++;
        case MergeAction.conflictKeepLocal:
          await store.saveConflictCopy(r!);
          state.noteShas[id] = rVersion!;
          state.dirty.add(id);
          conflicts++;
      }
    }
    state.dirty.removeWhere((id) => store.byId(id) == null);
    await store.saveState();

    // ---- push: encrypt and upload every dirty note -------------------------
    final pushed = <String, String>{}; // id -> new md5
    final pushedAt = <String, int>{};
    final created = <String, DriveFile>{}; // note files this sync created
    for (final id in state.dirty.toList()) {
      final n = store.byId(id)!;
      final enc = await vault.encrypt(utf8.encode(jsonEncode(n.toJson())));
      final existing = remoteNotes[id];
      if (existing != null) {
        // Another device may have written this note since we listed. If so,
        // leave ours dirty: the next sync pulls theirs and merges.
        if (await c.md5Of(existing.id) != existing.md5) continue;
        pushedAt[id] = n.updatedAt.millisecondsSinceEpoch;
        pushed[id] = (await c.update(existing.id, enc)).md5;
      } else {
        pushedAt[id] = n.updatedAt.millisecondsSinceEpoch;
        final file = await c.create('$_notePrefix$id$_ext', enc);
        created[id] = file;
        pushed[id] = file.md5;
      }
      wrote = true;
    }

    // Two devices can create the same note file at the same moment (typically
    // right after both switched to Drive). Drive keeps both, and the oldest
    // wins. If ours lost, remove it now and keep the note dirty without a
    // remembered version, so the next sync merges it with the winner instead
    // of silently replacing our newer edit later.
    var lostRace = 0;
    if (created.isNotEmpty) {
      final again = _byName(await c.list()).winners;
      for (final e in created.entries) {
        final winner = again['$_notePrefix${e.key}$_ext'];
        if (winner != null && winner.id != e.value.id) {
          await c.delete(e.value.id);
          pushed.remove(e.key);
          pushedAt.remove(e.key);
          state.noteShas.remove(e.key);
          lostRace++;
        }
      }
    }

    // ---- attachments: upload what the repository lacks ----------------------
    final names = <String, String>{};
    Future<String> nameFor(String hash) async =>
        names[hash] ??= await vault.blobName(hash);
    final uploaded = <String, DriveFile>{};
    for (final n in store.all) {
      for (final a in n.attachments) {
        final name = await nameFor(a.hash);
        if (remoteBlobs.containsKey(name) || uploaded.containsKey(name)) continue;
        final file = store.blobFile(a.hash);
        if (!await file.exists()) continue; // not downloaded on this device
        final enc = await vault.encrypt(await file.readAsBytes());
        uploaded[name] = await c.create('$_blobPrefix$name$_ext', enc);
        wrote = true;
      }
    }

    // ---- clean up unused attachments after a grace period -------------------
    final referenced = <String>{};
    for (final n in store.all) {
      for (final a in n.attachments) {
        referenced.add(await nameFor(a.hash));
      }
    }
    state.orphanSince.removeWhere(
        (name, _) => referenced.contains(name) || !remoteBlobs.containsKey(name));
    final removed = <String>[];
    for (final e in remoteBlobs.entries) {
      if (referenced.contains(e.key) || uploaded.containsKey(e.key)) continue;
      final since = state.orphanSince.putIfAbsent(e.key, () => nowMs);
      if (nowMs - since >= kOrphanGrace.inMilliseconds) {
        await c.delete(e.value.id);
        removed.add(e.key);
        wrote = true;
      }
    }

    // Duplicate files with one name come from two devices creating the same
    // file at once. The oldest wins; later copies are deleted once old
    // enough that no device is still mid-write.
    final stale = DateTime.now().subtract(const Duration(minutes: 10));
    for (final f in listing.extras) {
      if (f.name == _meta) continue; // never touch the key file here
      if ((f.created ?? DateTime.now()).isBefore(stale)) {
        await c.delete(f.id);
        wrote = true;
      }
    }

    // ---- bookkeeping ----------------------------------------------------------
    for (final e in pushed.entries) {
      state.noteShas[e.key] = e.value;
      final current = store.byId(e.key);
      if (current != null &&
          current.updatedAt.millisecondsSinceEpoch == pushedAt[e.key]) {
        state.dirty.remove(e.key);
      }
    }
    state.blobShas
      ..clear()
      ..addEntries(remoteBlobs.entries.map((e) => MapEntry(e.key, e.value.md5)))
      ..addEntries(uploaded.entries.map((e) => MapEntry(e.key, e.value.md5)));
    for (final name in removed) {
      state.blobShas.remove(name);
      state.orphanSince.remove(name);
    }
    // Our own writes changed the listing, so only remember it when nothing was
    // written; otherwise the next sync does one more (cheap) check.
    state.lastHead = wrote ? null : signature;
    await store.saveState();

    return SyncReport(
      pulled: pulled,
      pushed: pushed.length,
      uploads: uploaded.length,
      conflicts: conflicts,
      removed: removed.length,
      remoteNotes: remoteNotes.length + created.length - lostRace,
    );
  }

  /// Returns the local file for an attachment, downloading and decrypting it
  /// from Drive first if this device does not have it yet.
  Future<File> ensureAttachment(AttachmentRef ref, {DriveClient? client}) async {
    final local = store.blobFile(ref.hash);
    if (await local.exists()) return local;
    if (client == null && !settings.syncReady) {
      throw SyncException(
          'This attachment is not on this device yet. Set up sync to download it.');
    }
    final c = client ?? _client();
    final byName = _byName(await c.list()).winners;
    final meta = byName[_meta];
    if (meta == null) throw SyncException('No synced data in Google Drive.');
    final vault = await _vaultFor(c, meta);
    final name = '$_blobPrefix${await vault.blobName(ref.hash)}$_ext';
    final f = byName[name];
    if (f == null) {
      throw SyncException(
          'The attachment has not been uploaded yet. Sync the device that added it.');
    }
    final bytes = await vault.decrypt(await c.download(f.id));
    final actual = toHex((await Sha256().hash(bytes)).bytes);
    if (actual != ref.hash) {
      throw SyncException('Downloaded attachment failed its integrity check.');
    }
    await store.storeBlob(ref.hash, Uint8List.fromList(bytes));
    return local;
  }

  // -------------------------------------------------------------------- vault

  Future<Vault> _vaultFor(DriveClient c, DriveFile? meta) async {
    final pass = _passphrase?.call() ?? settings.drivePassphrase;
    if (meta == null) {
      final salt = Vault.randomSalt();
      final vault = await Vault.derive(pass, salt);
      final doc = {
        'v': 1,
        'kdf': 'pbkdf2-sha256',
        'iter': kKdfIterations,
        'salt': base64Encode(salt),
        'check': base64Encode(await vault.makeCheck()),
      };
      final created = await c.create(
          _meta, Uint8List.fromList(utf8.encode(jsonEncode(doc))));

      // Two devices setting up at once would each make a key file. Re-check
      // and use the oldest, so both end up with the same key.
      final again = _byName(await c.list()).winners[_meta];
      if (again != null && again.id != created.id) {
        await c.delete(created.id);
        return _vaultFor(c, again);
      }
      _vault = vault;
      _vaultMd5 = created.md5;
      _vaultPass = pass;
      return vault;
    }
    if (_vault != null && _vaultMd5 == meta.md5 && _vaultPass == pass) {
      return _vault!;
    }
    final vault = await _deriveFromMeta(await c.download(meta.id), pass);
    _vault = vault;
    _vaultMd5 = meta.md5;
    _vaultPass = pass;
    return vault;
  }

  Future<Vault> _deriveFromMeta(List<int> bytes, String passphrase) async {
    final meta = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final vault = await Vault.derive(
      passphrase,
      Uint8List.fromList(base64Decode(meta['salt'] as String)),
      iterations: (meta['iter'] as num?)?.toInt() ?? kKdfIterations,
    );
    await vault.verifyCheck(base64Decode(meta['check'] as String));
    return vault;
  }

  // ------------------------------------------------------------------ helpers

  /// Groups files by name. Drive allows duplicate names, so the oldest file of
  /// each name wins and the rest are reported as extras.
  static ({Map<String, DriveFile> winners, List<DriveFile> extras}) _byName(
      List<DriveFile> files) {
    final sorted = [...files]..sort((a, b) {
        final ca = a.created, cb = b.created;
        if (ca == null && cb == null) return a.id.compareTo(b.id);
        if (ca == null) return 1;
        if (cb == null) return -1;
        final c = ca.compareTo(cb);
        return c != 0 ? c : a.id.compareTo(b.id);
      });
    final winners = <String, DriveFile>{};
    final extras = <DriveFile>[];
    for (final f in sorted) {
      if (winners.containsKey(f.name)) {
        extras.add(f);
      } else {
        winners[f.name] = f;
      }
    }
    return (winners: winners, extras: extras);
  }

  static Future<String> _signature(Map<String, DriveFile> byName) async {
    final keys = byName.keys.toList()..sort();
    final joined = keys.map((k) => '$k:${byName[k]!.md5}').join('|');
    return toHex((await Sha256().hash(utf8.encode(joined))).bytes);
  }
}
