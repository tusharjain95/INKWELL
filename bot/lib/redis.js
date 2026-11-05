// Tiny Upstash Redis client over its REST API (no dependencies).
// Works with the Upstash integration from the Vercel Marketplace, which
// provides either UPSTASH_REDIS_REST_* or the older KV_REST_API_* names.

const baseUrl = () =>
  (process.env.UPSTASH_REDIS_REST_URL || process.env.KV_REST_API_URL || '').replace(/\/$/, '');
const authToken = () =>
  process.env.UPSTASH_REDIS_REST_TOKEN || process.env.KV_REST_API_TOKEN || '';

/** Runs one Redis command, e.g. redis('HSET', 'key', 'field', 'value'). */
export async function redis(...command) {
  const base = baseUrl();
  if (!base) throw new Error('Redis is not configured');
  const r = await fetch(base, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${authToken()}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(command),
  });
  const j = await r.json().catch(() => ({}));
  if (!r.ok || j.error) throw new Error(`Redis error: ${j.error || r.status}`);
  return j.result;
}
