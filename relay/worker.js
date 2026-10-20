// ugk-coach-relay：AI 训练助理中转。DeepSeek key 只放在这里（secret OPENCSG_API_KEY），
// App 只带可吊销的 App 令牌（secret APP_TOKENS，JSON：{"flarelab":"…","hiplab":"…"}）。
const UPSTREAM = 'https://opencsg.com/aigateway/v1';
const MODEL = 'deepseek-v4.1-flash-1017';
const MAX_TOKENS_CAP = 8000;
const MAX_BODY_BYTES = 64 * 1024;
const ALLOWED = ['messages', 'max_tokens', 'temperature', 'top_p', 'response_format', 'stream', 'stream_options'];

const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { 'Content-Type': 'application/json; charset=utf-8' } });
const err = (status, code, message) => json({ error: { code, message } }, status);

function appOf(token, env) {
  if (!token) return null;
  let map = {};
  try { map = JSON.parse(env.APP_TOKENS || '{}'); } catch (_) { return null; }
  for (const [app, t] of Object.entries(map)) if (t && t === token) return app;
  return null;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (req.method === 'GET' && (url.pathname === '/' || url.pathname === '/health')) {
      return json({ ok: true, service: 'ugk-coach-relay', model: MODEL, upstreamKey: Boolean(env.OPENCSG_API_KEY) });
    }
    if (url.pathname !== '/v1/chat/completions') return err(404, 'not_found', 'only /v1/chat/completions');
    if (req.method !== 'POST') return err(405, 'method_not_allowed', 'POST only');

    const app = appOf(req.headers.get('X-App-Token'), env);
    if (!app) return err(401, 'bad_app_token', 'invalid X-App-Token');
    if (!env.OPENCSG_API_KEY) return err(503, 'upstream_key_missing', 'relay not configured');

    if (env.RL) {
      const ip = req.headers.get('CF-Connecting-IP') || 'unknown';
      const { success } = await env.RL.limit({ key: `${app}:${ip}` });
      if (!success) return err(429, 'rate_limited', 'too many requests, retry later');
    }

    const raw = await req.text();
    if (raw.length > MAX_BODY_BYTES) return err(413, 'too_large', 'request body too large');
    let body;
    try { body = JSON.parse(raw); } catch (_) { return err(400, 'bad_json', 'invalid JSON'); }
    if (!Array.isArray(body.messages) || body.messages.length === 0) return err(400, 'bad_request', 'messages required');

    const out = { model: MODEL };
    for (const k of ALLOWED) if (k in body) out[k] = body[k];
    out.max_tokens = Math.min(Number(body.max_tokens) || 6000, MAX_TOKENS_CAP);

    const t0 = Date.now();
    const up = await fetch(`${UPSTREAM}/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${env.OPENCSG_API_KEY}` },
      body: JSON.stringify(out),
    });
    console.log(JSON.stringify({ app, status: up.status, ms: Date.now() - t0 }));
    const headers = new Headers(up.headers);
    headers.delete('set-cookie');
    headers.set('X-Relay-App', app);
    return new Response(up.body, { status: up.status, headers });
  },
};
