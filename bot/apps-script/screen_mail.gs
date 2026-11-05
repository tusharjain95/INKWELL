/**
 * Inkwell mail screening, for Google Apps Script (free, runs in your Google
 * account, no server needed for the Gmail part).
 *
 * It looks for the emails that matter (tax-portal notices, "due date" and
 * "reminder" mails, senders you name), pulls out any deadline it finds, and
 * posts each one to your Inkwell bot, which turns it into a task.
 *
 * Setup is in bot/README.md. In short: paste this file into a new project at
 * script.google.com, fill in the two values below, run installTrigger() once
 * and approve the Gmail permission.
 */

// ---- fill these in -------------------------------------------------------
const BOT_URL = 'https://YOUR-PROJECT.vercel.app'; // no trailing slash
const INKWELL_KEY = 'PASTE-THE-SAME-INKWELL_KEY-AS-ON-VERCEL';

// ---- tune these ----------------------------------------------------------
const LABEL = 'Inkwell'; // added to every mail that was sent on, so it is never repeated
const LOOKBACK = 'newer_than:3d';
const MAX_PER_RUN = 15;

// Senders you always want to hear about (client or partner addresses).
const VIP_SENDERS = []; // e.g. ['ceo@bigclient.com', 'partner@firm.com']

/**
 * Each rule is a Gmail search plus how urgent a match is.
 * priority: 1 high, 2 medium, 3 low. defaultDueDays is used when the email
 * itself names no deadline, so the task still comes up in your digest.
 */
const RULES = [
  {
    name: 'Government portals',
    query:
      'from:(incometax.gov.in OR gst.gov.in OR gstn.org.in OR mca.gov.in OR tdscpc.gov.in ' +
      'OR traces.gov.in OR cbic.gov.in OR cbic-gst.gov.in OR epfindia.gov.in OR esic.gov.in)',
    priority: 2,
    defaultDueDays: 3,
  },
  {
    name: 'Due dates and reminders',
    query:
      'subject:("due date" OR "last date" OR "payment due" OR overdue OR reminder OR ' +
      '"final notice" OR "action required")',
    priority: 2,
    defaultDueDays: 2,
  },
  {
    name: 'VIP senders',
    query: VIP_SENDERS.length ? 'from:(' + VIP_SENDERS.join(' OR ') + ')' : '',
    priority: 2,
    defaultDueDays: 1,
  },
];

// Words that make a mail high priority whatever rule found it.
const URGENT_WORDS =
  /\b(notice|demand|show[- ]cause|scrutiny|intimation|penalty|DRC-\d+|ASMT-\d+|assessment order|default|prosecution)\b/i;

const BASE_QUERY = '-from:me -in:spam -in:trash -category:promotions -category:social';

// ---- entry points --------------------------------------------------------

/** Runs on a timer. */
function screenMail() {
  run_(false);
}

/** Try it: logs what it would send, sends nothing and labels nothing. */
function dryRun() {
  run_(true);
}

/** Run once to start screening every 10 minutes. */
function installTrigger() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    if (t.getHandlerFunction() === 'screenMail') ScriptApp.deleteTrigger(t);
  });
  ScriptApp.newTrigger('screenMail').timeBased().everyMinutes(10).create();
}

function run_(dry) {
  const label = dry ? null : GmailApp.getUserLabelByName(LABEL) || GmailApp.createLabel(LABEL);
  let sent = 0;
  for (var i = 0; i < RULES.length; i++) {
    const rule = RULES[i];
    if (!rule.query) continue;
    const q = rule.query + ' ' + LOOKBACK + ' ' + BASE_QUERY + ' -label:' + LABEL;
    const threads = GmailApp.search(q, 0, MAX_PER_RUN);
    for (var j = 0; j < threads.length; j++) {
      if (sent >= MAX_PER_RUN) return;
      const thread = threads[j];
      const msgs = thread.getMessages();
      const msg = msgs[msgs.length - 1];
      const item = buildItem_(rule, thread.getId(), {
        subject: msg.getSubject(),
        from: msg.getFrom(),
        plain: msg.getPlainBody(),
        date: msg.getDate(),
      });
      if (dry) {
        Logger.log('[' + rule.name + '] ' + JSON.stringify(item));
        sent++;
        continue;
      }
      if (post_(item)) {
        thread.addLabel(label);
        sent++;
      }
    }
  }
}

function post_(item) {
  try {
    const r = UrlFetchApp.fetch(BOT_URL + '/api/mail', {
      method: 'post',
      contentType: 'application/json',
      headers: { Authorization: 'Bearer ' + INKWELL_KEY },
      payload: JSON.stringify(item),
      muteHttpExceptions: true,
    });
    if (r.getResponseCode() === 200) return true;
    Logger.log('Bot answered ' + r.getResponseCode() + ': ' + r.getContentText());
  } catch (e) {
    Logger.log('Could not reach the bot: ' + e);
  }
  return false;
}

// ---- pure helpers (tested in bot/test/mail_script.test.js) ----------------

function buildItem_(rule, threadId, m) {
  const text = (m.subject || '') + '\n' + (m.plain || '');
  const ref = m.date || new Date();
  var due = extractDue(text, ref);
  var note = '';
  if (!due) {
    due = isoDate_(addDays_(ref, rule.defaultDueDays));
    note = 'No deadline found in the email, so the due date is a placeholder.\n\n';
  }
  const priority = URGENT_WORDS.test(text) ? 1 : rule.priority;
  const subject = cleanSubject(m.subject || '(no subject)');
  const who = senderName(m.from || '');
  const flat = (m.plain || '').replace(/\s+/g, ' ').trim().slice(0, 500);
  return {
    key: threadId,
    title: (who ? who + ': ' : '') + subject,
    body: note + flat,
    from: m.from || '',
    link: 'https://mail.google.com/mail/u/0/#inbox/' + threadId,
    due: due,
    priority: priority,
  };
}

function cleanSubject(s) {
  return s
    .replace(/^\s*((re|fwd?|fw)\s*:\s*)+/i, '')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 140);
}

function senderName(from) {
  const m = /^\s*"?([^"<]+?)"?\s*<.*>\s*$/.exec(from);
  const name = (m ? m[1] : from).trim();
  return name.indexOf('@') >= 0 ? name.split('@')[0] : name;
}

function addDays_(d, n) {
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n);
}

function isoDate_(d) {
  const p = function (n) { return (n < 10 ? '0' : '') + n; };
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate());
}

const MONTH_NUM_ = {
  jan: 1, january: 1, feb: 2, february: 2, mar: 3, march: 3, apr: 4, april: 4,
  may: 5, jun: 6, june: 6, jul: 7, july: 7, aug: 8, august: 8, sep: 9, sept: 9,
  september: 9, oct: 10, october: 10, nov: 11, november: 11, dec: 12, december: 12,
};

// Words that introduce a deadline, matched just before a date.
const KEYWORD_BEFORE_ =
  /(?:on or before|not later than|latest by|before|by|due(?: date| on| by)?|last date(?: of [a-z ]{0,25})?|deadline(?: is| of)?|up to|till|until)[:\s,\-]*$/i;

function toDate_(y, mo, d) {
  if (y < 100) y += 2000;
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) return null;
  const dt = new Date(y, mo - 1, d);
  return dt.getMonth() === mo - 1 ? dt : null; // rejects 31 Feb and the like
}

/**
 * Finds the earliest upcoming deadline in [text], or null.
 * Only dates introduced by words like "by", "on or before" or "due date" are
 * trusted, plus "within N days" counted from [ref]. Arbitrary dates (the
 * notice's own date, a financial year) are ignored. Dates are read day-first.
 * Returns "YYYY-MM-DD".
 */
function extractDue(text, ref) {
  ref = ref || new Date();
  const floor = addDays_(ref, -1);
  const found = [];

  function consider(match, date) {
    if (!date) return;
    const before = text.slice(Math.max(0, match.index - 45), match.index);
    if (KEYWORD_BEFORE_.test(before) && !(date < floor)) found.push(date);
  }

  var m;
  const numeric = /(\d{1,2})[\/.\-](\d{1,2})[\/.\-](\d{2,4})/g;
  while ((m = numeric.exec(text))) consider(m, toDate_(+m[3], +m[2], +m[1]));

  const dayMonth = /(\d{1,2})(?:st|nd|rd|th)?[\s\-]*(?:of\s+)?([A-Za-z]{3,9})\.?,?[\s\-]+(\d{2,4})/g;
  while ((m = dayMonth.exec(text))) {
    const mo = MONTH_NUM_[m[2].toLowerCase()];
    if (mo) consider(m, toDate_(+m[3], mo, +m[1]));
  }

  const monthDay = /([A-Za-z]{3,9})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})/g;
  while ((m = monthDay.exec(text))) {
    const mo = MONTH_NUM_[m[1].toLowerCase()];
    if (mo) consider(m, toDate_(+m[3], mo, +m[2]));
  }

  const within = /within\s+(\d{1,3})\s+(?:working\s+|calendar\s+)?days/gi;
  while ((m = within.exec(text))) {
    const n = +m[1];
    if (n >= 1 && n <= 365) found.push(addDays_(ref, n));
  }

  if (!found.length) return null;
  found.sort(function (a, b) { return a - b; });
  return isoDate_(found[0]);
}
