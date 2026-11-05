import { telegramOk } from '../lib/auth.js';
import { jsonBody, telegramSend } from '../lib/http.js';
import { push } from '../lib/queue.js';

/**
 * Telegram webhook. Anything the owner sends the bot is queued for Inkwell.
 * Always answers 200 once the request is authentic, so Telegram never retries
 * a message that was deliberately ignored.
 */
export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  if (!telegramOk(req)) return res.status(401).json({ error: 'bad secret' });

  const msg = jsonBody(req).message;
  if (!msg) return res.status(200).json({ ok: true }); // edits, reactions, etc.

  const chatId = String(msg.chat?.id ?? '');
  const owner = String(process.env.TELEGRAM_CHAT_ID || '');
  const text = String(msg.text ?? msg.caption ?? '').trim();

  if (/^\/start\b/i.test(text)) {
    await telegramSend(
      chatId,
      owner && chatId === owner
        ? 'Connected to Inkwell. Send a task or note, or reply to a digest with "done 2".'
        : `Your chat id is ${chatId}. Put it in the TELEGRAM_CHAT_ID setting on Vercel, redeploy, and send /start again.`
    );
    return res.status(200).json({ ok: true });
  }

  // Strangers who find the bot get no answer at all.
  if (!owner || chatId !== owner) return res.status(200).json({ ok: true });

  if (!text) {
    await telegramSend(chatId, 'Only text is supported for now. Add a caption or type it out.');
    return res.status(200).json({ ok: true });
  }

  try {
    await push({
      kind: 'message',
      text: text.slice(0, 4000),
      forwarded: Boolean(msg.forward_origin || msg.forward_date),
    });
    await telegramSend(chatId, '📥 Received. It will appear in Inkwell shortly.');
  } catch (e) {
    await telegramSend(chatId, `⚠️ Could not save that: ${e.message}`);
  }
  return res.status(200).json({ ok: true });
}
