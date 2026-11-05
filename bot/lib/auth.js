import { createHash, timingSafeEqual } from 'node:crypto';

function same(a, b) {
  const ha = createHash('sha256').update(String(a)).digest();
  const hb = createHash('sha256').update(String(b)).digest();
  return timingSafeEqual(ha, hb);
}

/** The app and the Apps Script prove themselves with INKWELL_KEY. */
export function bearerOk(req) {
  const key = process.env.INKWELL_KEY || '';
  if (key.length < 16) return false; // fail closed on a missing or weak key
  const m = /^Bearer (.+)$/.exec(req.headers?.authorization || '');
  return !!m && same(m[1], key);
}

/** Telegram proves itself with the secret_token given to setWebhook. */
export function telegramOk(req) {
  const secret = process.env.TELEGRAM_SECRET || '';
  if (secret.length < 8) return false;
  return same(req.headers?.['x-telegram-bot-api-secret-token'] || '', secret);
}
