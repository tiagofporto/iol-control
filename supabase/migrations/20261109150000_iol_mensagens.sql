-- Mensagens internas: conversas diretas (entre duas pessoas) e fio de conversa por item.
--  * Só lê quem participa; mensagens não podem ser editadas nem apagadas (somente inserção, por função).
--  * Fio por item: qualquer usuário com acesso abre o fio de um item; quem escreve entra como participante, e os usuários
--    dos setores envolvidos (setor do item e setores indicados nas justificativas) entram junto a cada nova mensagem.
--  * Não lida = mensagem de outra pessoa com id maior que o "lido_ate" do participante.

create table public.conversas (
  id          bigint generated always as identity primary key,
  tipo        text not null check (tipo in ('direta', 'item')),
  item_id     bigint references public.iol_itens (id) on delete cascade,
  par         text,                                   -- direta: 'uuid menor|uuid maior' (uma conversa por par)
  criado_por  uuid references public.perfis (id) on delete set null default auth.uid(),
  criado_em   timestamptz not null default now(),
  ultima_em   timestamptz not null default now(),
  check ((tipo = 'item' and item_id is not null and par is null) or (tipo = 'direta' and item_id is null and par is not null))
);
create unique index conversas_item_uk on public.conversas (item_id) where tipo = 'item';
create unique index conversas_par_uk on public.conversas (par) where tipo = 'direta';
create index conversas_criado_por_idx on public.conversas (criado_por);

create table public.conversa_membros (
  conversa_id bigint not null references public.conversas (id) on delete cascade,
  usuario_id  uuid not null references public.perfis (id) on delete cascade,
  lido_ate    bigint not null default 0,
  entrou_em   timestamptz not null default now(),
  primary key (conversa_id, usuario_id)
);
create index conversa_membros_usuario_idx on public.conversa_membros (usuario_id);

create table public.mensagens (
  id          bigint generated always as identity primary key,
  conversa_id bigint not null references public.conversas (id) on delete cascade,
  autor_id    uuid references public.perfis (id) on delete set null,
  autor_nome  text not null,
  texto       text not null check (char_length(texto) between 1 and 2000),
  criado_em   timestamptz not null default now()
);
create index mensagens_conversa_idx on public.mensagens (conversa_id, id);
create index mensagens_autor_idx on public.mensagens (autor_id);

alter table public.conversas enable row level security;
alter table public.conversa_membros enable row level security;
alter table public.mensagens enable row level security;
create policy conv_membros_sel on public.conversa_membros for select to authenticated using (usuario_id = (select auth.uid()));
create policy conv_sel on public.conversas for select to authenticated
  using (id in (select m.conversa_id from public.conversa_membros m where m.usuario_id = (select auth.uid())));
create policy msg_sel on public.mensagens for select to authenticated
  using (conversa_id in (select m.conversa_id from public.conversa_membros m where m.usuario_id = (select auth.uid())));
revoke all on public.conversas, public.conversa_membros, public.mensagens from anon, authenticated;
grant select on public.conversas, public.conversa_membros, public.mensagens to authenticated;

-- ---------------------------------------------------------------- escrita (somente por estas funções)
create or replace function private.msg_ativo()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select coalesce((select p.papel in ('operador', 'gestor', 'admin') from public.perfis p where p.id = (select auth.uid())), false); $$;

create or replace function private.msg_abrir_direta(p_usuario uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_eu  uuid := (select auth.uid());
  v_par text;
  v_id  bigint;
begin
  if v_eu is null or not private.msg_ativo() then raise exception 'Sem acesso às mensagens.' using errcode = '42501'; end if;
  if p_usuario is null or p_usuario = v_eu then raise exception 'Escolha outra pessoa para conversar.'; end if;
  if not exists (select 1 from public.perfis p where p.id = p_usuario and p.papel in ('operador', 'gestor', 'admin')) then
    raise exception 'Esse usuário não tem acesso ao sistema.';
  end if;
  v_par := least(v_eu::text, p_usuario::text) || '|' || greatest(v_eu::text, p_usuario::text);
  insert into public.conversas (tipo, par, criado_por) values ('direta', v_par, v_eu)
    on conflict (par) where tipo = 'direta' do nothing;
  select c.id into v_id from public.conversas c where c.tipo = 'direta' and c.par = v_par;
  insert into public.conversa_membros (conversa_id, usuario_id) values (v_id, v_eu), (v_id, p_usuario) on conflict do nothing;
  return v_id;
end;
$$;

create or replace function private.msg_abrir_item(p_item bigint)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_eu uuid := (select auth.uid());
  v_id bigint;
begin
  if v_eu is null or not private.msg_ativo() then raise exception 'Sem acesso às mensagens.' using errcode = '42501'; end if;
  if not exists (select 1 from public.iol_itens i where i.id = p_item) then raise exception 'Item não encontrado.'; end if;
  insert into public.conversas (tipo, item_id, criado_por) values ('item', p_item, v_eu)
    on conflict (item_id) where tipo = 'item' do nothing;
  select c.id into v_id from public.conversas c where c.tipo = 'item' and c.item_id = p_item;
  insert into public.conversa_membros (conversa_id, usuario_id) values (v_id, v_eu) on conflict do nothing;
  return v_id;
end;
$$;

create or replace function private.msg_enviar_def(p_conversa bigint, p_texto text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_eu   uuid := (select auth.uid());
  v_txt  text := btrim(coalesce(p_texto, ''));
  v_nome text;
  c      public.conversas;
  m      public.mensagens;
begin
  if v_eu is null or not private.msg_ativo() then raise exception 'Sem acesso às mensagens.' using errcode = '42501'; end if;
  if v_txt = '' then raise exception 'Escreva uma mensagem.'; end if;
  if char_length(v_txt) > 2000 then raise exception 'A mensagem pode ter até 2.000 caracteres.'; end if;
  select * into c from public.conversas where id = p_conversa;
  if not found or not exists (select 1 from public.conversa_membros x where x.conversa_id = p_conversa and x.usuario_id = v_eu) then
    raise exception 'Conversa não encontrada.';
  end if;
  select p.nome into v_nome from public.perfis p where p.id = v_eu;
  insert into public.mensagens (conversa_id, autor_id, autor_nome, texto) values (p_conversa, v_eu, coalesce(v_nome, 'Usuário'), v_txt) returning * into m;
  update public.conversas set ultima_em = m.criado_em where id = p_conversa;
  update public.conversa_membros set lido_ate = m.id where conversa_id = p_conversa and usuario_id = v_eu;
  if c.tipo = 'item' then
    -- avisa quem atua nos setores envolvidos: setor do item + setores indicados nas justificativas
    insert into public.conversa_membros (conversa_id, usuario_id, lido_ate)
    select p_conversa, p.id, 0
      from public.perfis p
     where p.papel in ('operador', 'gestor', 'admin') and p.setor_id is not null
       and p.setor_id in (select i.setor_id from public.iol_itens i where i.id = c.item_id
                          union select l.setor_destino_id from public.iol_lancamentos l where l.item_id = c.item_id and l.setor_informado and l.setor_destino_id is not null)
    on conflict do nothing;
  end if;
  return jsonb_build_object('id', m.id, 'conversa_id', m.conversa_id, 'autor_id', m.autor_id, 'autor_nome', m.autor_nome, 'texto', m.texto, 'criado_em', m.criado_em);
end;
$$;

create or replace function private.msg_marcar_def(p_conversa bigint)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.conversa_membros m
     set lido_ate = greatest(m.lido_ate, coalesce((select max(x.id) from public.mensagens x where x.conversa_id = p_conversa), 0))
   where m.conversa_id = p_conversa and m.usuario_id = (select auth.uid());
$$;
revoke all on function private.msg_ativo(), private.msg_abrir_direta(uuid), private.msg_abrir_item(bigint), private.msg_enviar_def(bigint, text), private.msg_marcar_def(bigint) from public, anon;
grant execute on function private.msg_ativo(), private.msg_abrir_direta(uuid), private.msg_abrir_item(bigint), private.msg_enviar_def(bigint, text), private.msg_marcar_def(bigint) to authenticated;

-- ---------------------------------------------------------------- API pública (invoker; leitura respeita a RLS)
create or replace function public.msg_abrir_direta(p_usuario uuid) returns bigint language sql security invoker set search_path = ''
as $$ select private.msg_abrir_direta(p_usuario); $$;
create or replace function public.msg_abrir_item(p_item bigint) returns bigint language sql security invoker set search_path = ''
as $$ select private.msg_abrir_item(p_item); $$;
create or replace function public.msg_enviar(p_conversa bigint, p_texto text) returns jsonb language sql security invoker set search_path = ''
as $$ select private.msg_enviar_def(p_conversa, p_texto); $$;
create or replace function public.msg_marcar_lida(p_conversa bigint) returns void language sql security invoker set search_path = ''
as $$ select private.msg_marcar_def(p_conversa); $$;

create or replace function public.msg_nao_lidas()
returns int
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(count(*), 0)::int
    from public.conversa_membros cm
    join public.mensagens m on m.conversa_id = cm.conversa_id and m.id > cm.lido_ate and m.autor_id is distinct from (select auth.uid())
   where cm.usuario_id = (select auth.uid());
$$;

-- Lista as conversas do usuário (fios por item só aparecem se já têm mensagem, ou se for o aberto agora)
create or replace function public.msg_conversas(p_incluir bigint default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.ultima_em desc, r.id desc), '[]'::jsonb)
    from (
      select c.id, c.tipo, c.item_id, c.ultima_em,
             (select count(*)::int from public.mensagens m where m.conversa_id = c.id and m.id > cm.lido_ate and m.autor_id is distinct from (select auth.uid())) as nao_lidas,
             o.id as outro_id, o.nome as outro_nome, o.funcao as outro_funcao, o.setor as outro_setor,
             i.sku, i.container, i.quantidade, i.resolvido_em, s.nome as setor_nome, inv.asin, inv.nome as item_nome,
             lm.texto as previa, lm.autor_nome as previa_autor
        from public.conversa_membros cm
        join public.conversas c on c.id = cm.conversa_id
        left join public.perfis o on c.tipo = 'direta'
             and o.id = (case when split_part(c.par, '|', 1) = (select auth.uid())::text then split_part(c.par, '|', 2) else split_part(c.par, '|', 1) end)::uuid
        left join public.iol_itens i on i.id = c.item_id
        left join public.iol_setores s on s.id = i.setor_id
        left join public.inventario_sku inv on inv.fcsku = i.sku
        left join lateral (select m.texto, m.autor_nome from public.mensagens m where m.conversa_id = c.id order by m.id desc limit 1) lm on true
       where cm.usuario_id = (select auth.uid())
         and (c.tipo = 'direta' or c.id = p_incluir or lm.texto is not null)
    ) r;
$$;

-- Mensagens de uma conversa: as últimas p_limite (p_apos = 0) ou só as novas depois de p_apos
create or replace function public.msg_listar(p_conversa bigint, p_apos bigint default 0, p_limite int default 200)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.id), '[]'::jsonb)
    from (
      select m.id, m.autor_id, m.autor_nome, m.texto, m.criado_em
        from public.mensagens m
       where m.conversa_id = p_conversa and m.id > coalesce(p_apos, 0)
       order by m.id desc
       limit least(greatest(coalesce(p_limite, 200), 1), 500)
    ) r;
$$;

-- Pessoas com quem se pode conversar (somente nome, função e setor)
create or replace function public.msg_pessoas()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by r.nome), '[]'::jsonb)
    from (select p.id, p.nome, p.funcao, p.setor from public.perfis p
           where p.papel in ('operador', 'gestor', 'admin') and p.id <> (select auth.uid())) r;
$$;

revoke execute on function public.msg_abrir_direta(uuid), public.msg_abrir_item(bigint), public.msg_enviar(bigint, text), public.msg_marcar_lida(bigint),
  public.msg_nao_lidas(), public.msg_conversas(bigint), public.msg_listar(bigint, bigint, int), public.msg_pessoas() from public, anon;
grant execute on function public.msg_abrir_direta(uuid), public.msg_abrir_item(bigint), public.msg_enviar(bigint, text), public.msg_marcar_lida(bigint),
  public.msg_nao_lidas(), public.msg_conversas(bigint), public.msg_listar(bigint, bigint, int), public.msg_pessoas() to authenticated;
