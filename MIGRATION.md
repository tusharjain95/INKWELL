# Moving to the new setup (keeps all your data)

Your notes live in your **sync storage** (GitHub repo or Google Drive folder),
encrypted with your passphrase. Nothing in this update touches that, so the
move is: install the new app, sign in the same way with the same passphrase,
and the notes come back. Telegram no longer needs Vercel.

## 0. Before you start (5 minutes, do not skip)

1. On the device that has the **most recent notes** (probably your phone), open
   the old app and tap the sync button until it says it is up to date.
2. Write down, somewhere safe, what the old app uses:
   - GitHub: repository (`owner/name`), branch, token, **backup passphrase**
   - or Google Drive: the Google account and your **backup passphrase**
   - Telegram: the bot token (BotFather > /mybots > your bot > API Token) and
     your numeric chat id (shown in Settings > Telegram, old version)
   The **passphrase is the one thing that cannot be recovered.**
3. Optional safety copy: on the PC, copy the folder
   `%APPDATA%\com.example\inkwell` (or open Settings > About for the path) to a
   backup folder. On Android, Settings > Apps > Inkwell is enough: the synced
   copy is your backup.

## 1. Install the new version

1. Unzip over `D:\inkwell` (replace all files). If a `pubspec.lock` exists,
   delete it.
2. Commit, push, tag a **new** version (for example `v4.2.0`) so the release
   workflow builds it.
3. Install the new Windows build and Android APK **over** the old ones (same
   signing key). Do not uninstall first: installing over keeps local data and
   settings, and the app updates itself from the release anyway.

Your settings (sync sign-in, passphrase, Telegram) survive an in-place update.
If anything looks signed out, re-enter the same values from step 0.

## 2. Telegram: switch to "no server"

On the phone (the device that is the Telegram hub):

1. Settings > Telegram and email. Your token and chat id are already filled in.
2. Tap **Check token**, then **Save and test**. You should get
   "Inkwell is connected" in Telegram.
   The app removes the old webhook by itself on the first check.
3. Make sure **Use this device as the Telegram hub** is on (phone only).
4. Send the bot `buy milk tomorrow`. Within about 2 minutes (15 when the app
   is closed) you get "Task added".

Anything you sent while the old server was still queued is picked up too, as
long as the old relay address and key are still saved under "Advanced".

## 3. What to do with Vercel and Upstash

- **Do you use Gmail screening?** Keep the Vercel project and Upstash database,
  and leave the relay address and key under *Advanced: email screening relay*.
  Telegram no longer touches it.
- **No Gmail screening?** Clear the relay address and key under Advanced, then
  you can delete the Vercel project and the Upstash database. Nothing else
  depends on them.

## 4. Second device (PC) in one step

1. On the phone: Settings > Set up another device > **Make a setup code**.
   Choose a PIN. Copy the code and send it to yourself (Telegram "Saved
   messages").
2. On the PC: Settings > Set up another device > **Enter a setup code**, paste
   the code, type the PIN. Sync and Telegram settings are filled in.
3. Sync. Do **not** turn on the Telegram hub on the PC.

## 5. Check everything

Settings > Health check > **Run checks**. Green ticks mean it works. Anything
red says what to fix.

## If something looks wrong

- Notes missing after sign-in: the passphrase differs from the one used before.
  Enter the original; wrong passphrases cannot read the old data (and do not
  damage it).
- "Telegram rejected the bot token": copy it again from BotFather
  (/mybots > API Token). If the old token was ever shared in a chat, use
  *Revoke current token* there first, then paste the new one.
- Bot silent: the hub must be on, on exactly one device, and that device must
  be online. Android checks every ~15 minutes when the app is closed.
