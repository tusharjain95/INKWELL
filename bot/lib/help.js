export const HELP_TEXT = `Inkwell bot

SAVE
Send or forward any text and it becomes a task or note in Inkwell.
  call Rahul tomorrow 5pm !1   (high-priority task)
  submit GSTR-3B friday 3pm    (task with a date and time)
  note: portal hint is ...     (a note)
Words like today, tomorrow, friday 3pm set the date. !1 is high, !2 medium, !3 low priority.

MANAGE
  list          today's tasks, numbered
  done 2        tick task 2 (several: done 1 3)
  snooze 2 fri  move task 2 (no date means a day later)
Numbers always refer to the latest list I sent.

GOOD TO KNOW
- Answers to list, done and snooze come from the Inkwell app on your hub device, usually within 2 minutes (up to about 15 if the app is closed).
- You also get a morning digest, an evening nudge, a Sunday review and alerts for overdue !1 tasks. Change them in Inkwell, Settings.
- Photos: add a caption, only the text is saved.
- /help shows this again.`;

/** What a bare command needs, so the user is told at once. */
export const USAGE = {
  done: 'Which task? Send the number from the latest list, for example: done 2 (or done 1 3).',
  snooze: 'Which task and when? For example: snooze 2 friday 10am. With no date it moves a day later.',
};

/** Commands the Inkwell app answers. Mirrors parseHubCommand in lib/core/hub.dart. */
export const APP_COMMAND = new RegExp(
  '^/?(?:' +
    'done(?:@\\w+)?\\s+\\d+(?:\\s*(?:,|&|and)?\\s*\\d+)*' + // done 2 / done 1, 3
    '|snooze(?:@\\w+)?\\s+\\d+(?:\\s+.+)?' + // snooze 2 / snooze 2 friday
    '|(?:list|today|tasks|digest)(?:@\\w+)?' + // list
  ')\\s*$',
  'is'
);

export function classify(text) {
  const t = text.trim();
  if (/^\/?(?:help|\?)(?:@\w+)?$/i.test(t)) return { kind: 'help' };
  const bare = /^\/?(done|snooze)(?:@\w+)?$/i.exec(t);
  if (bare) return { kind: 'usage', which: bare[1].toLowerCase() };
  if (APP_COMMAND.test(t)) return { kind: 'command' };
  return { kind: 'capture' };
}
