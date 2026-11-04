// Administração de usuários (somente administradores): cria contas já liberadas e redefine senhas.
// Usa a service role (variável de ambiente do próprio Supabase); a chave nunca vai para o navegador.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, status = 200) => new Response(JSON.stringify(o), { status, headers: { ...cors, 'Content-Type': 'application/json' } });
const PAPEIS = ['pendente', 'operador', 'gestor', 'admin'];
const txt = (v: unknown, max: number) => String(v ?? '').trim().slice(0, max);

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ erro: 'Método não permitido.' }, 405);
  try {
    const admin = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, { auth: { persistSession: false } });
    const token = (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '');
    const { data: u } = await admin.auth.getUser(token);
    if (!u?.user) return json({ erro: 'Sessão inválida. Entre novamente.' }, 401);
    const { data: eu } = await admin.from('perfis').select('papel').eq('id', u.user.id).maybeSingle();
    if (eu?.papel !== 'admin') return json({ erro: 'Somente administradores podem fazer isso.' }, 403);

    const b = await req.json();
    if (b.acao === 'criar') {
      const email = txt(b.email, 200).toLowerCase(), senha = String(b.senha ?? ''), nome = txt(b.nome, 120);
      const login = txt(b.login, 30).toLowerCase() || null, papel = PAPEIS.includes(b.papel) ? b.papel : 'operador';
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return json({ erro: 'E-mail inválido.' }, 400);
      if (!nome) return json({ erro: 'Informe o nome.' }, 400);
      if (senha.length < 8) return json({ erro: 'A senha provisória precisa de ao menos 8 caracteres.' }, 400);
      if (login && !/^[a-z0-9._-]{3,30}$/.test(login)) return json({ erro: 'Login: 3 a 30 caracteres (letras minúsculas, números, ponto, hífen e sublinhado).' }, 400);
      if (login) {
        const { data: ex } = await admin.from('perfis').select('id').eq('login', login).maybeSingle();
        if (ex) return json({ erro: 'Já existe um usuário com esse login.' }, 409);
      }
      const { data: c, error } = await admin.auth.admin.createUser({ email, password: senha, email_confirm: true, user_metadata: { nome } });
      if (error || !c.user) return json({ erro: /already|registered/i.test(error?.message ?? '') ? 'Já existe um usuário com esse e-mail.' : (error?.message ?? 'Não foi possível criar o usuário.') }, 400);
      const { error: e2 } = await admin.from('perfis').update({ nome, login, setor: txt(b.setor, 80) || null, funcao: txt(b.funcao, 80) || null, manager: txt(b.manager, 120) || null, papel }).eq('id', c.user.id);
      if (e2) return json({ erro: 'Usuário criado, mas o perfil não foi salvo: ' + e2.message, id: c.user.id }, 500);
      return json({ ok: true, id: c.user.id });
    }
    if (b.acao === 'senha') {
      const senha = String(b.senha ?? '');
      if (!b.id || senha.length < 8) return json({ erro: 'Informe o usuário e uma senha de ao menos 8 caracteres.' }, 400);
      const { error } = await admin.auth.admin.updateUserById(String(b.id), { password: senha });
      if (error) return json({ erro: error.message }, 400);
      return json({ ok: true });
    }
    return json({ erro: 'Ação desconhecida.' }, 400);
  } catch (e) {
    return json({ erro: (e as Error).message ?? 'Erro inesperado.' }, 500);
  }
});
