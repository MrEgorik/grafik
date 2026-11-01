// Посредник «График ассистентов» → Supabase для Yandex Cloud Functions (Node.js 18 или новее).
// Пересылает запросы программы в базу Supabase, когда она недоступна напрямую.
// Принимает только запросы к базе (/rest/v1/ и /auth/v1/) и только с сайта программы.
// Базы, в которые разрешено пересылать: рабочая и тестовая.
const BASES = {
  buynizqyabifntjqxgrx: 'https://buynizqyabifntjqxgrx.supabase.co', // рабочая
  qrlzktxrmhpdlbjmgxxy: 'https://qrlzktxrmhpdlbjmgxxy.supabase.co', // тестовая
};
const DEFAULT_BASE = 'buynizqyabifntjqxgrx';
const ALLOW = ['https://mregorik.github.io'];
const PASS_HEADERS = ['apikey', 'authorization', 'content-type', 'prefer', 'accept', 'accept-profile', 'content-profile', 'x-client-info', 'x-supabase-api-version'];

module.exports.handler = async (event) => {
  const hdr = event.headers || {};
  const origin = hdr.Origin || hdr.origin || '';
  const cors = { 'Access-Control-Allow-Origin': ALLOW.includes(origin) ? origin : ALLOW[0], 'Vary': 'Origin' };

  if (event.httpMethod === 'OPTIONS') {
    return { statusCode: 204, headers: { ...cors, 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'Content-Type', 'Access-Control-Max-Age': '86400' }, body: '' };
  }
  if (event.httpMethod !== 'POST') return { statusCode: 405, headers: cors, body: 'Method not allowed' };

  let req;
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body || '', 'base64').toString('utf8') : (event.body || '');
    req = JSON.parse(raw);
  } catch (e) {
    return { statusCode: 400, headers: cors, body: 'Bad request' };
  }

  const SUPA = BASES[String(req.t || DEFAULT_BASE)];
  if (!SUPA) return { statusCode: 400, headers: cors, body: 'Unknown base' };
  const path = String(req.u || '');
  if (!/^\/(rest|auth)\/v1\//.test(path)) return { statusCode: 400, headers: cors, body: 'Bad path' };
  const method = String(req.m || 'GET').toUpperCase();
  const headers = {};
  for (const [k, v] of Object.entries(req.h || {})) {
    if (PASS_HEADERS.includes(k.toLowerCase())) headers[k.toLowerCase()] = String(v);
  }

  let r;
  try {
    r = await fetch(SUPA + path, { method, headers, body: (method === 'GET' || method === 'HEAD') ? undefined : (req.b ?? undefined) });
  } catch (e) {
    return { statusCode: 502, headers: cors, body: JSON.stringify({ message: 'Посредник не достучался до базы' }) };
  }
  const out = { ...cors, 'Content-Type': r.headers.get('content-type') || 'application/json' };
  const range = r.headers.get('content-range');
  if (range) { out['Content-Range'] = range; out['Access-Control-Expose-Headers'] = 'Content-Range'; }
  return { statusCode: r.status, headers: out, body: await r.text() };
};
