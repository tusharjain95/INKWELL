# Inkwell

Fast, private notes for **Android** and **Windows**, written in Flutter.
Rich-text notes with image / PDF / file attachments. Sync is end-to-end
encrypted into a **private GitHub repository you own**, using a free
fine-grained token. No server, no account, no subscription.

Inspired by the sync design of [YATA](https://github.com/rjwarrier/yata)
(private repo + fine-grained token + passphrase encryption + commit-history
restore points), extended for notes and attachments.

> **Status: scaffold, still uncompiled.** It was written without a Flutter SDK
> available, so it has not been compiled or run yet. The natural-language
> parser's logic was checked against a Python reference (39 cases); nothing
> else has been executed. Expect to fix a handful of small
> compile errors on the first `flutter analyze` (most likely in the
> `flutter_quill` toolbar/editor config, plus the `workmanager` and
> `speech_to_text` calls, whose APIs shift between versions).
> Start with "First run" below.

## First run

Prerequisites: Flutter (stable). Windows builds also need Visual Studio 2022
with the "Desktop development with C++" workload **including ATL**
(`flutter_secure_storage` needs it). Android builds need the Android SDK.

```bash
dart run tool/bootstrap.dart      # generates android/ + windows/, applies patches
flutter pub get
flutter analyze                   # fix anything it reports
flutter test                      # crypto, merge, store and version tests
flutter run -d windows            # or an Android device/emulator
```

Commit the generated `android/` and `windows/` folders once they work.
`bootstrap.dart` is idempotent, and CI runs it too.

## Set up sync

1. On GitHub create a **private** repository (tick "Add a README"), e.g. `inkwell-sync`.
2. GitHub → Settings → Developer settings → Personal access tokens →
   **Fine-grained tokens** → Generate. Repository access: *only* that repo.
   Permissions → **Contents: Read and write**.
3. In Inkwell: Settings → GitHub sync. Enter `owner/repo`, branch, token and a
   **backup passphrase**, then *Save & connect*.
4. On every other device enter the same repo, a token, and the same passphrase.

Inkwell refuses public repositories. Lose the passphrase and synced data
cannot be recovered; the token alone reveals nothing.

## How sync works

```
inkwell/meta.json               salt + encrypted passphrase check (only plaintext file)
inkwell/notes/<id>.enc          one encrypted file per note
inkwell/blobs/<keyed-hash>.enc  one encrypted file per attachment
```

- **Crypto:** PBKDF2-HMAC-SHA256 (210k iterations) -> AES-256-GCM, random
  nonce per file. Attachment file names are an HMAC of their content hash, so
  the repo does not reveal names, types or whether you hold a known file.
- **Atomic commits:** each sync is one commit built with the Git Data API
  (blobs -> tree -> commit -> fast-forward ref update). If another device
  pushed first, the update is rejected and the sync retries.
- **Per-note merge:** a note edited on one device is simply taken or pushed.
  If the same note changed on two devices, the newer version wins and the
  other is kept as `"<title> (conflict copy)"`. Nothing is ever overwritten
  silently.
- **Deletes** are tombstones, so they propagate. Sync never deletes remote
  files, so a wiped or reinstalled device cannot erase your data.
- **Attachments download on demand** (tap to fetch), so a phone on mobile data
  does not pull every PDF. Max 25 MB each (GitHub's hard limit is 100 MB).
- **History:** every sync is a git commit, so older versions are recoverable
  from the repository.
- Local data is stored as plain files in the app's private folder; only the
  copy in GitHub is encrypted.

## Releases (Windows + Android together)

```bash
git tag v0.1.0 && git push origin v0.1.0
```

`.github/workflows/release.yml` builds both platforms in parallel and attaches
them to **one** GitHub Release:

| Asset | |
|---|---|
| `inkwell-android.apk` | signed release APK |
| `inkwell-windows-setup.exe` | per-user installer (no admin prompt) |
| `inkwell-windows-portable.zip` | unzip-and-run |

Run the workflow manually for a dry run that builds but publishes nothing.
Tags with a suffix (`v1.0.0-beta.1`) become pre-releases, which the in-app
updater ignores.

### Release signing (one-time)

Android only installs an update if it is signed with the **same key** as the
installed app. Create the key once and keep a backup outside GitHub:

```bash
keytool -genkey -v -keystore upload-keystore.jks -keyalg RSA -keysize 2048 \
        -validity 10000 -alias inkwell
base64 -w0 upload-keystore.jks          # macOS: base64 -i upload-keystore.jks
# PowerShell: [Convert]::ToBase64String([IO.File]::ReadAllBytes("upload-keystore.jks"))
```

Add these repository secrets (Settings -> Secrets and variables -> Actions):
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_PASSWORD`,
`ANDROID_KEY_ALIAS`.

Windows builds are unsigned, so SmartScreen shows a warning on first run
("More info" -> "Run anyway"). Code signing needs a paid certificate.

### In-app updates

Release builds know their own repository (`--dart-define=UPDATE_REPO`, set by
the workflow). On launch, and from Settings -> Check for updates, the app
reads `releases/latest`:

- **Android:** downloads the APK and opens the system installer (you confirm).
  The first time, Android asks to allow installs from Inkwell.
- **Windows:** downloads the installer and runs it silently over the existing
  install, then relaunches. Data is kept.

This requires the app repository (not the sync repository) to be **public**,
so release assets can be downloaded without a token. For a private app repo,
share builds manually.

## Photos, background sync, voice and tasks

**Image compression.** Photos are resized and re-encoded when you attach them
(Settings → Photos: Original / Balanced 2048 px / Small 1280 px). The result is
only kept if it is at least 10% smaller. PNGs stay PNG only when they really use
transparency. Re-encoding strips EXIF, including GPS location. Other files are
stored untouched.

**Android background sync.** WorkManager runs a sync roughly every 30 minutes
while the app is closed (network required, not on low battery). Android decides
the exact timing and may delay it further in battery saver or Doze. The app and
the worker share a lock file so they never sync at once, and the app reloads
notes from disk when it returns to the foreground. Windows has no background
sync; it syncs while the app is open.

**Quick add and voice.** The mic button opens Quick add: say or type
"remind me to call Rahul friday 3pm !1 #work" and Inkwell makes a task with a
due date and time, priority and tag. "note: idea for the trip" makes a note.
Inside a note, the mic button dictates at the cursor. Tasks have a due date and
time, priority, repeat (daily, weekly, monthly, yearly) and a done checkbox;
the list has All / Tasks / Today views. Ticking a repeating task moves it to its
next occurrence.

Honest limits:

- Parsing is rule-based pattern matching on the device, not an AI model, and
  understands **English only**. Unusual wording may need a manual edit; the
  preview in Quick add shows what it understood before you save.
- "Prefer on-device recognition" is a request to the OS speech engine. It
  works offline only when the offline language pack is installed; otherwise the
  device may use its online speech service. Inkwell never uploads audio itself.
- On Windows, voice input depends on the system's speech recognition being
  enabled; if it is not available the app says so and you can use Win+H.
- Windows reminders only fire while Inkwell is running (tray counts).

## Google Drive sync (alternative to GitHub)

In **Settings → Sync to**, choose **Google Drive**. Inkwell stores everything
(notes, tasks, attachments) end-to-end encrypted with your passphrase, in the
a folder named **Inkwell Sync** in your own Drive. Inkwell asks only for the
`drive.file` scope, so it can see just the files it created, never the rest of
your Drive. Don't edit or delete files in that folder; they are encrypted.

One-time setup by whoever builds the app (about 10 minutes, free):

1. Go to <https://console.cloud.google.com>, create a project, and enable the
   **Google Drive API**.
2. **OAuth consent screen**: user type External, add scopes
   `.../auth/drive.file` and `email`, then **Publish app** (move it from
   *Testing* to *In production*). Left in Testing, Google expires sign-ins
   after 7 days. These scopes are non-sensitive, so no verification is needed.
3. **Credentials → Create credentials → OAuth client ID**, application type
   **TVs and Limited Input devices**. Copy the client ID and client secret.
4. In the GitHub repo: **Settings → Secrets and variables → Actions**, add
   `GOOGLE_CLIENT_ID` and `GOOGLE_CLIENT_SECRET`.
5. Push a new tag (for example `v2.6.0`) to build and release.

In the app, tap **Sign in with Google**, open google.com/device on any
browser, and enter the code shown. Use the same passphrase on every device.

Switching provider re-uploads what exists on this device to the new place;
attachments not yet downloaded here cannot be re-uploaded.

## Reminders, sharing, tray and cleanup

**Task reminders.** A task with a due date notifies you when it is due. On
Android the reminder is handed to the system alarm service, so it works with the
app closed and survives a reboot. Allow notifications when asked; if reminders
arrive late, also allow "Alarms & reminders" and set Inkwell's battery use to
unrestricted. Tasks that have a date but no time notify at a time you choose
(Settings, default 09:00). On Windows, unpackaged apps cannot use scheduled
toasts, so reminders fire while Inkwell is running, which includes sitting in
the system tray.

**Share to Inkwell.** Share text, a link, photos or PDFs from any Android app and
pick Inkwell: it creates a note with the text and the files attached (photos are
compressed per your setting). On Windows, drop files onto the window to make a
note with them attached.

**Windows tray.** Closing the window hides Inkwell in the system tray so syncing
and reminders keep running; quit from the tray menu. Optionally start with
Windows (minimised). Only one copy runs; launching it again shows the first.
Tray mode replaces the lack of a Windows background service. If the installer
cannot replace a running copy, quit it from the tray first.

**Attachment cleanup.** Attachments that no note uses any more are deleted from
the repository 14 days after sync first notices, so a device that was offline can
still sync. Git history keeps older versions, so this trims the current files
but does not shrink the repository's history. Sync also re-uploads an attachment
that a synced note references but the repository lacks, if this device has it.

## Project layout

```
lib/core/    models, AES-GCM vault, merge rules, store, settings, NL parser, image compression, speech
lib/sync/    GitHub client, sync engine, Android background sync, release updater
lib/ui/      notes list, editor + attachments, settings, update dialog
test/        crypto, merge, store, tasks, parser, compression, lock tests
tool/        bootstrap.dart (platform folders + patches)
installer/   Inno Setup script for the Windows installer
.github/     CI (analyze + test) and the release workflow
```

## Known gaps / next steps

- PDFs open in your system PDF app. An in-app viewer (`pdfrx`) is a good
  addition but adds ~10 MB per platform.
- Only images are compressed; PDFs and other files are stored as picked.
- Removed attachments stay in the repository's git history.
- Windows installer and APK are universal builds; add `--split-per-abi` to
  shrink the APK.
