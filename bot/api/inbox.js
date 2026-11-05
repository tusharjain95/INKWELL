import { bearerOk } from '../lib/auth.js';
import { jsonBody } from '../lib/http.js';
import { ack, list } from '../lib/queue.js';

/**
 * GET  -> the waiting items (oldest first, at most 50).
 * POST -> { ack: [ids] } removes items the app has safely stored.
 */
export default async function handler(req, res) {
  if (!bearerOk(req)) return res.status(401).json({ error: 'unauthorised' });
  try {
    if (req.method === 'GET') return res.status(200).json({ items: await list(50) });
    if (req.method === 'POST') {
      const ids = jsonBody(req).ack;
      const removed = Array.isArray(ids) ? await ack(ids) : 0;
      return res.status(200).json({ removed });
    }
    return res.status(405).json({ error: 'GET or POST only' });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
}
