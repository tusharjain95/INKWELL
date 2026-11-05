import assert from 'node:assert/strict';
import { beforeEach, describe, it } from 'node:test';

import inbox from '../api/inbox.js';
import mail from '../api/mail.js';
import telegram from '../api/telegram.js';

// ---- fakes ---------------------------------------------------------------
let hash;
let seen;
let sent;

function installFetch() {
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url);
    const body = init.body ? JSON.parse(init.body) : null;
    if (u.startsWith('https://redis.test')) {
      const [cmd, ...a] = body;
      let result = null;
      switch (cmd) {
        case 'HLEN': result = hash.size; break;
        case 'HSET': hash.set(a[1], a[2]); result = 1; break;
        case 'HGETALL': result = [...hash].flat(); break;
        case 'HDEL': result = a.slice(1).filter((id) => hash.delete(id)).length; break;
        case 'SET':
          if (seen.has(a[0])) result = null;
          else { seen.add(a[0]); result = 'OK'; }
          break;
        default: throw new Error(`unexpected redis command ${cmd}`);
      }
      return new Response(JSON.stringify({ result }), { status: 200 });
    }
    if (u.startsWith('https://api.telegram.org/')) {
      sent.push(body);
      return new Response('{"ok":true}', { status: 200 });
    }
    throw new Error(`unexpected fetch ${u}`);
  };
}

function res() {
  const r = { code: 0, body: undefined };
  r.status = (c) => { r.code = c; return r; };
  r.json = (b) => { r.body = b; return r; };
  return r;
}
const call = async (fn, req) => { const r = res(); await fn(req, r); return r; };

const KEY = 'k'.repeat(24);
const bearer = { authorization: `Bearer ${KEY}` };
const tgHeaders = { 'x-telegram-bot-api-secret-token': 'secret-123' };
const update = (text, chat = 42) => ({ message: { message_id: 1, chat: { id: chat }, text } });

beforeEach(() => {
  hash = new Map();
  seen = new Set();
  sent = [];
  installFetch();
  process.env.UPSTASH_REDIS_REST_URL = 'https://redis.test';
  process.env.UPSTASH_REDIS_REST_TOKEN = 't';
  process.env.INKWELL_KEY = KEY;
  process.env.TELEGRAM_SECRET = 'secret-123';
  process.env.TELEGRAM_CHAT_ID = '42';
  process.env.TELEGRAM_BOT_TOKEN = 'bot-token';
});

describe('telegram webhook', () => {
  it('rejects a request without the secret', async () => {
    const r = await call(telegram, { method: 'POST', headers: {}, body: update('hi') });
    assert.equal(r.code, 401);
    assert.equal(hash.size, 0);
  });

  it('queues the owner\'s message and acknowledges it', async () => {
    const r = await call(telegram, { method: 'POST', headers: tgHeaders, body: update('call Rahul tomorrow 5pm') });
    assert.equal(r.code, 200);
    const items = [...hash.values()].map((v) => JSON.parse(v));
    assert.equal(items.length, 1);
    assert.equal(items[0].kind, 'message');
    assert.equal(items[0].text, 'call Rahul tomorrow 5pm');
    assert.match(sent[0].text, /Received/);
  });

  it('silently ignores other people', async () => {
    const r = await call(telegram, { method: 'POST', headers: tgHeaders, body: update('hello', 999) });
    assert.equal(r.code, 200);
    assert.equal(hash.size, 0);
    assert.equal(sent.length, 0);
  });

  it('/start tells a new user their chat id', async () => {
    delete process.env.TELEGRAM_CHAT_ID;
    await call(telegram, { method: 'POST', headers: tgHeaders, body: update('/start', 777) });
    assert.match(sent[0].text, /777/);
    assert.equal(hash.size, 0);
  });

  it('uses a photo caption but refuses empty messages', async () => {
    const cap = { message: { chat: { id: 42 }, caption: 'GST challan', photo: [{}] } };
    await call(telegram, { method: 'POST', headers: tgHeaders, body: cap });
    assert.equal(hash.size, 1);
    const empty = { message: { chat: { id: 42 }, photo: [{}] } };
    await call(telegram, { method: 'POST', headers: tgHeaders, body: empty });
    assert.equal(hash.size, 1);
    assert.match(sent.at(-1).text, /Only text/);
  });

  it('accepts a JSON string body', async () => {
    await call(telegram, { method: 'POST', headers: tgHeaders, body: JSON.stringify(update('x y')) });
    assert.equal(hash.size, 1);
  });
});

describe('mail endpoint', () => {
  const post = (body, headers = bearer) => call(mail, { method: 'POST', headers, body });

  it('needs the key', async () => {
    assert.equal((await post({ title: 'x' }, {})).code, 401);
    assert.equal((await post({ title: 'x' }, { authorization: 'Bearer wrong' })).code, 401);
  });

  it('fails closed when no key is configured', async () => {
    delete process.env.INKWELL_KEY;
    assert.equal((await post({ title: 'x' }, { authorization: 'Bearer ' })).code, 401);
  });

  it('needs a title', async () => {
    assert.equal((await post({ body: 'x' })).code, 400);
  });

  it('queues a task and ignores a repeat of the same thread', async () => {
    const a = await post({ title: 'Notice u/s 143(1)', key: 'thread-1', due: '2026-12-05', priority: 1 });
    assert.equal(a.code, 200);
    const b = await post({ title: 'Notice u/s 143(1)', key: 'thread-1' });
    assert.equal(b.body.duplicate, true);
    assert.equal(hash.size, 1);
    const item = JSON.parse([...hash.values()][0]);
    assert.equal(item.kind, 'mail');
    assert.equal(item.priority, 1);
    assert.equal(item.due, '2026-12-05');
  });

  it('drops an unparseable due date and a bad priority', async () => {
    await post({ title: 'x', due: 'soon', priority: 9 });
    const item = JSON.parse([...hash.values()][0]);
    assert.equal(item.due, null);
    assert.equal(item.priority, 0);
  });
});

describe('inbox endpoint', () => {
  it('needs the key', async () => {
    assert.equal((await call(inbox, { method: 'GET', headers: {} })).code, 401);
  });

  it('lists oldest first and removes what was acknowledged', async () => {
    hash.set('b', JSON.stringify({ id: 'b', at: '2026-01-02T00:00:00Z', kind: 'message', text: 'second' }));
    hash.set('a', JSON.stringify({ id: 'a', at: '2026-01-01T00:00:00Z', kind: 'message', text: 'first' }));
    const got = await call(inbox, { method: 'GET', headers: bearer });
    assert.deepEqual(got.body.items.map((i) => i.id), ['a', 'b']);

    const done = await call(inbox, { method: 'POST', headers: bearer, body: { ack: ['a', 'nope'] } });
    assert.equal(done.body.removed, 1);
    const again = await call(inbox, { method: 'GET', headers: bearer });
    assert.deepEqual(again.body.items.map((i) => i.id), ['b']);
  });

  it('survives a corrupt entry', async () => {
    hash.set('x', 'not json');
    hash.set('a', JSON.stringify({ id: 'a', at: '2026-01-01T00:00:00Z' }));
    const got = await call(inbox, { method: 'GET', headers: bearer });
    assert.equal(got.body.items.length, 1);
  });
});
