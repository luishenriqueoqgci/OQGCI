// Função do Netlify que lê a história de venda com a API do Claude.
// Fica desligada até você definir, no painel do Netlify (Site configuration > Environment variables):
//   ANTHROPIC_API_KEY  -> chave criada no Console do Claude
//   SUPABASE_URL       -> o mesmo Project URL do config.js
//   SUPABASE_ANON_KEY  -> a mesma chave anon public do config.js
// e marcar leituraIA: true em public/config.js.
// Só usuários logados no diagnóstico conseguem chamar a função.

export default async (req) => {
  const json = (body, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  const { ANTHROPIC_API_KEY, SUPABASE_URL, SUPABASE_ANON_KEY, ANTHROPIC_MODEL } = process.env;
  if (!ANTHROPIC_API_KEY || !SUPABASE_URL || !SUPABASE_ANON_KEY) return json({ error: 'not_configured' }, 501);

  const token = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '');
  if (!token) return json({ error: 'unauthorized' }, 401);
  const who = await fetch(`${SUPABASE_URL}/auth/v1/user`, { headers: { apikey: SUPABASE_ANON_KEY, authorization: `Bearer ${token}` } });
  if (!who.ok) return json({ error: 'unauthorized' }, 401);

  let prompt;
  try { ({ prompt } = await req.json()); } catch { return json({ error: 'bad_request' }, 400); }
  if (typeof prompt !== 'string' || prompt.length > 20000) return json({ error: 'bad_request' }, 400);

  const r = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    headers: { 'x-api-key': ANTHROPIC_API_KEY, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
    body: JSON.stringify({ model: ANTHROPIC_MODEL || 'claude-sonnet-5-5', max_tokens: 1500, messages: [{ role: 'user', content: prompt }] })
  });
  if (!r.ok) return json({ error: 'upstream', status: r.status }, 502);
  const data = await r.json();
  const text = (data.content || []).map(c => c.text || '').join('');
  return json({ text });
};
