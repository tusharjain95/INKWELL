import { bearerOk } from '../lib/auth.js';
import { jsonBody } from '../lib/http.js';
import { firstTime, push } from '../lib/queue.js';

/**
 * Receives one screened email from the Gmail Apps Script and queues it as a
 * task for Inkwell. `key` (the Gmail thread id) makes repeats harmless.
 */
export default async function handler(req, res) {
  if (req.method !== 'POST') return res.status(405).json({ error: 'POST only' });
  if (!bearerOk(req)) return res.status(401).json({ error: 'unauthorised' });

  const b = jsonBody(req);
  const title = typeof b.title === 'string' ? b.title.trim().slice(0, 300) : '';
  if (!title) return res.status(400).json({ error: 'title is required' });

  const due = typeof b.due === 'string' && !Number.isNaN(Date.parse(b.due)) ? b.due : null;
  const priority = [1, 2, 3].includes(b.priority) ? b.priority : 0;
  const key = typeof b.key === 'string' ? b.key.slice(0, 120) : '';

  try {
    if (key && !(await firstTime(`mail:${key}`))) {
      return res.status(200).json({ ok: true, duplicate: true });
    }
    const item = await push({
      kind: 'mail',
      title,
      body: typeof b.body === 'string' ? b.body.slice(0, 2000) : '',
      from: typeof b.from === 'string' ? b.from.slice(0, 200) : '',
      link: typeof b.link === 'string' ? b.link.slice(0, 500) : '',
      due,
      priority,
    });
    return res.status(200).json({ ok: true, id: item.id });
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }
}
