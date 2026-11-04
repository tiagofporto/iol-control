// Login por "usuário": resolve o e-mail no servidor e autentica, sem nunca devolver o e-mail ao navegador.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const MSG = 'Login ou senha incorretos.';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ erro: 'Método não permitido.' }, 405);
  try {
    const b = await req.json();
    const login = String(b.login ?? '').trim().toLowerCase().slice(0, 60);
    const senha = String(b.senha ?? '');
    if (!login || !senha) return json({ erro: MSG }, 400);
    const url = Deno.env.get('SUPABASE_URL')!;
    const admin = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const { data: p } = await admin.from('perfis').select('email').eq('login', login).maybeSingle();
    // login inexistente: mesma resposta e mesmo custo de uma senha errada (não revela quais logins existem)
    const anon = createClient(url, Deno.env.get('SUPABASE_ANON_KEY')!, { auth: { persistSession: false } });
    const { data, error } = await anon.auth.signInWithPassword({ email: p?.email ?? 'inexistente@invalid.local', password: senha });
    if (error || !data.session) return json({ erro: MSG }, 401);
    return json({ access_token: data.session.access_token, refresh_token: data.session.refresh_token });
  } catch {
    return json({ erro: 'Não foi possível entrar agora. Tente de novo.' }, 500);
  }
});
