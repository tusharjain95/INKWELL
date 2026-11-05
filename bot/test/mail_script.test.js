import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import vm from 'node:vm';

// Load the Apps Script file as-is and pull out its pure helpers.
const src = readFileSync(new URL('../apps-script/screen_mail.gs', import.meta.url), 'utf8');
const lib = vm.runInNewContext(
  `${src}\n({ extractDue, cleanSubject, senderName, buildItem_, RULES })`,
  { Logger: { log() {} } }
);

const ref = new Date(2026, 10, 4); // 4 Nov 2026

describe('extractDue', () => {
  const cases = [
    ['Please reply on or before 30/11/2026.', '2026-11-30'],
    ['Last date of filing is 15-Dec-2026', '2026-12-15'],
    ['Response is due by 5th December 2026 failing which', '2026-12-05'],
    ['Deadline: December 20, 2026', '2026-12-20'],
    ['not later than 7.12.26', '2026-12-07'],
    ['You must respond within 15 days of receipt', '2026-11-19'],
    ['Due date 12/11/2026', '2026-11-12'], // day first
    ['Reply by 10 Nov 2026 or by 25 Nov 2026', '2026-11-10'], // earliest wins
  ];
  for (const [text, want] of cases) {
    it(`reads "${text}"`, () => assert.equal(lib.extractDue(text, ref), want));
  }

  it('ignores dates that are not deadlines', () => {
    assert.equal(lib.extractDue('Notice dated 01/10/2026 for FY 2025-26', ref), null);
  });
  it('ignores deadlines already long past', () => {
    assert.equal(lib.extractDue('Reply by 01/01/2025', ref), null);
  });
  it('rejects impossible dates', () => {
    assert.equal(lib.extractDue('by 31/02/2026', ref), null);
  });
  it('returns null for nothing', () => {
    assert.equal(lib.extractDue('Hello there', ref), null);
  });
});

describe('helpers', () => {
  it('cleans subjects', () => {
    assert.equal(lib.cleanSubject('Re: RE: Fwd:  GST   notice '), 'GST notice');
  });
  it('shortens senders', () => {
    assert.equal(lib.senderName('"Income Tax Dept" <noreply@incometax.gov.in>'), 'Income Tax Dept');
    assert.equal(lib.senderName('rahul@client.com'), 'rahul');
  });
});

describe('buildItem_', () => {
  const rule = lib.RULES[0];

  it('marks a notice high priority and keeps the found deadline', () => {
    const item = lib.buildItem_(rule, 't1', {
      subject: 'Notice under section 143(1)',
      from: 'IT Dept <a@incometax.gov.in>',
      plain: 'Please respond on or before 30/11/2026.',
      date: ref,
    });
    assert.equal(item.priority, 1);
    assert.equal(item.due, '2026-11-30');
    assert.equal(item.key, 't1');
    assert.match(item.title, /^IT Dept: Notice/);
    assert.match(item.link, /t1$/);
  });

  it('falls back to a placeholder due date and says so', () => {
    const item = lib.buildItem_(rule, 't2', {
      subject: 'Your portal update',
      from: 'a@gst.gov.in',
      plain: 'Nothing dated here.',
      date: ref,
    });
    assert.equal(item.priority, 2);
    assert.equal(item.due, '2026-11-07');
    assert.match(item.body, /placeholder/);
  });
});
