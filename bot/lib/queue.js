import { randomBytes } from 'node:crypto';
import { redis } from './redis.js';

const KEY = 'inkwell:inbox';
const MAX_ITEMS = 500;

/**
 * Items wait here, as JSON in one Redis hash, until the Inkwell app collects
 * and acknowledges them. Delivery is at-least-once; the app skips repeats.
 */
export async function push(item) {
  const size = Number(await redis('HLEN', KEY)) || 0;
  if (size >= MAX_ITEMS) throw new Error('The inbox is full. Open Inkwell to collect it.');
  const id = `${Date.now().toString(36)}${randomBytes(4).toString('hex')}`;
  const full = { id, at: new Date().toISOString(), ...item };
  await redis('HSET', KEY, id, JSON.stringify(full));
  return full;
}

export async function list(limit = 50) {
  const flat = (await redis('HGETALL', KEY)) || [];
  const items = [];
  for (let i = 1; i < flat.length; i += 2) {
    try {
      items.push(JSON.parse(flat[i]));
    } catch {
      /* skip a corrupt entry */
    }
  }
  items.sort((a, b) => String(a.at).localeCompare(String(b.at)));
  return items.slice(0, limit);
}

export async function ack(ids) {
  const clean = ids.filter((x) => typeof x === 'string' && x.length > 0 && x.length <= 64);
  if (clean.length === 0) return 0;
  return Number(await redis('HDEL', KEY, ...clean)) || 0;
}

/** True the first time a key is seen (90 days), false for repeats. */
export async function firstTime(key) {
  const r = await redis('SET', `inkwell:seen:${key}`, '1', 'NX', 'EX', '7776000');
  return r === 'OK';
}
