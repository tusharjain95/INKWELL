> **Note:** Telegram messages are now read directly by the app, so this server is only needed for **email screening**. If you do not use Gmail screening you can delete the Vercel project and Upstash database.

# Inkwell bot: Telegram, email screening and digests

Everything here runs on free plans: Telegram, Vercel Hobby, Upstash Redis and
Google Apps Script. Allow about 30 minutes for the first setup.

## What you get

* **Capture from Telegram.** Message or forward anything to your bot
  ("call Rahul tomorrow 5pm !1") and it becomes a task or note in Inkwell,
  parsed by the same on-device parser as Quick Add.
* **Reply to manage tasks.** `list`, `done 2`, `snooze 2 friday 10am`.
* **Email screening.** Tax-portal notices, "due date" mails and senders you
  name become tasks, with the deadline pulled out of the text.
* **Messages from the app:** a morning digest, an evening nudge, a weekly
  review and escalation of overdue high-priority (`!1`) tasks.
* **Quiet hours** for reminders and Telegram messages.

## How the pieces fit

```
Telegram ──webhook──> Vercel (api/telegram) ─┐
Gmail ──Apps Script──> Vercel (api/mail) ────┼─> Upstash Redis (a short-lived inbox)
                                             │
Inkwell on ONE device ── api/inbox ──────────┘   collects items, creates the tasks,
        │                                        then acknowledges them
        └── Telegram Bot API ──> your chat       digests, nudges, replies
```

Your synced notes stay end-to-end encrypted. The server never sees them and
never gets your passphrase. What does pass through is what you choose to send:
messages you type to the bot, the subject and first 500 characters of screened
emails (held in Redis only until the app collects them), and the digests the
app sends to Telegram, which contain task titles. Telegram bot chats are not
end-to-end encrypted. If that matters for client matters, leave client names
out of task titles or switch the digests off.

## 1. Create the Telegram bot

1. In Telegram open **@BotFather**, send `/newbot`, pick a name and a username.
2. Copy the **token** it gives you (`123456:ABC...`). Keep it private.

## 2. Create the inbox (Upstash Redis, free)

In the Vercel dashboard go to **Storage** (or **Marketplace**) and add
**Upstash Redis**, choosing the free plan. Connect it to your project in step 3
and Vercel adds the environment variables for you. If you create the database
at upstash.com instead, add `UPSTASH_REDIS_REST_URL` and
`UPSTASH_REDIS_REST_TOKEN` yourself.

## 3. Deploy the bot on Vercel

1. **Add New → Project**, import your Inkwell GitHub repository.
2. Set **Root Directory** to `bot`. Framework preset: **Other**.
3. Add these **Environment Variables**:

   | Name | Value |
   |---|---|
   | `TELEGRAM_BOT_TOKEN` | the token from step 1 |
   | `TELEGRAM_SECRET` | a random string, 20+ characters |
   | `INKWELL_KEY` | a random string, 32+ characters |
   | `TELEGRAM_CHAT_ID` | add later (step 5) |

   Random strings in PowerShell:
   `-join ((48..57)+(97..122) | Get-Random -Count 32 | % {[char]$_})`
4. **Deploy.** Note the address, e.g. `https://inkwell-bot.vercel.app`.

## 4. Point Telegram at it

Open this in a browser, with your own values:

```
https://api.telegram.org/bot<TOKEN>/setWebhook?url=https://<your-project>.vercel.app/api/telegram&secret_token=<TELEGRAM_SECRET>
```

You should see `{"ok":true,"result":true,...}`.

## 5. Tell the bot who you are

1. Send `/start` to your bot. It replies with your **chat id**.
2. Add it as `TELEGRAM_CHAT_ID` in Vercel (Settings → Environment Variables).
3. **Redeploy** (Deployments → the latest one → ⋯ → Redeploy).
4. Send `/start` again. It should say *Connected to Inkwell*.

Anyone else who finds the bot gets no reply and nothing is stored.

## 6. Connect the app

On the device that should do the work (your phone is the best choice, since
Android can check in the background):

1. **Settings → Telegram and email**: fill in the bot address, the Inkwell key
   (`INKWELL_KEY`), the bot token and your chat id.
2. Tap **Save and test**. You should get a Telegram message from the bot.
3. Switch on **Use this device as the Telegram hub**.

Turn the hub on for **one device only**. Two hubs would each send a digest and
split the incoming items between them. Tasks created by the hub reach your
other devices through the normal sync.

Timing: while the app is open the hub checks every 2 minutes. With the app
closed, Android checks about every 15 minutes, so a message can take that long
to appear, and a digest can arrive a little after its set time. On Windows the
hub works while Inkwell runs, including in the tray.

## 7. Email screening (Gmail)

1. Go to <https://script.google.com> → **New project**.
2. Paste in the contents of `apps-script/screen_mail.gs`.
3. At the top set `BOT_URL` (your Vercel address) and `INKWELL_KEY`.
4. Edit `RULES` and `VIP_SENDERS` to suit you.
5. Choose the function `dryRun` and press **Run**. Approve the Gmail
   permission. Google may warn that the app is unverified: it is your own
   script, so choose **Advanced → Go to … (unsafe)**. Open **Execution log**
   to see what it would send.
6. Run `installTrigger` once. It then checks every 10 minutes.

Each email that is sent on gets the Gmail label **Inkwell**, so it is never
sent twice. Remove the label from a thread to send it again.

How deadlines are found: only dates introduced by words such as "on or
before", "by", "due date" or "last date" count, plus "within N days" from the
day the email arrived. If none is found, the task gets a placeholder due date
a few days out, and says so in its notes.

## Add the command menu (optional)

In Telegram open @BotFather, send `/setcommands`, choose your bot, and paste:

```
list - Today's tasks
help - How to use this bot
done - Tick tasks, e.g. done 2
snooze - Move a task, e.g. snooze 2 friday
```

The bot then shows a menu button next to the message box. `/help` and `/start`
are answered by the bot itself at once. `list`, `done` and `snooze` are
answered by the Inkwell app, so they take a moment.

## Using it

| You send | What happens |
|---|---|
| `call Rahul tomorrow 5pm !1` | a high-priority task due tomorrow 17:00 |
| `note: portal hint is ...` | a note |
| `list` | today's tasks, numbered |
| `done 2` or `done 1 3` | ticks those tasks from the latest list |
| `snooze 2 friday 10am` | moves task 2 (no date means a day later) |
| `help` | the list of commands |

Numbers always refer to the latest numbered message the app sent.

## Free-plan limits

The app checks the inbox every 2 minutes while open (about 720 checks a day,
one Redis command each) and every 15 minutes in the background. That is far
below the free plans' limits at the time of writing, but plans change, so
check the current Vercel and Upstash limits if you grow this.

## Troubleshooting

| Symptom | Check |
|---|---|
| Test says "key rejected" | the Inkwell key in the app equals `INKWELL_KEY` exactly |
| Test says "address not found" | the Vercel address, with no `/api` on the end |
| Bot never answers | the `setWebhook` call returned `ok`; `TELEGRAM_SECRET` matches |
| `/start` shows a chat id forever | `TELEGRAM_CHAT_ID` set, then redeployed |
| Messages arrive but no task appears | the hub is switched on, on one device, and the app has run |
| Digest did not arrive | the hub device was off or asleep; quiet hours; check the status line in Settings |
| Email script posts nothing | run `dryRun` and read the log; check the Gmail search in `RULES` |

## Tests

```
cd bot
node --test
```
