-- Notificações: quando alguém indica um setor para tratar itens, os usuários desse setor recebem um aviso
-- (uma notificação por lançamento em lote, com total de itens e unidades), até marcarem como lida.

-- 1) Vínculo do usuário com o setor do IOL (derivado do campo "Setor" do perfil, por nome ou código)
alter table public.perfis add column setor_id text references public.iol_setores (id) on delete set null;
create index perfis_setor_id_idx on public.perfis (setor_id) where setor_id is not null;

create or replace function private.perfis_setor_id()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  new.setor_id := (select s.id from public.iol_setores s
                    where lower(btrim(s.nome)) = lower(btrim(coalesce(new.setor, ''))) or s.id = lower(btrim(coalesce(new.setor, ''))) limit 1);
  return new;
end;
$$;
revoke all on function private.perfis_setor_id() from public, anon;
grant execute on function private.perfis_setor_id() to authenticated;
create trigger perfis_setor_id before insert or update of setor on public.perfis
  for each row execute function private.perfis_setor_id();
update public.perfis p set setor = p.setor where p.setor is not null;   -- preenche setor_id dos perfis já existentes

-- 2) Notificações
create table public.notificacoes (
  id          bigint generated always as identity primary key,
  usuario_id  uuid not null references public.perfis (id) on delete cascade,
  tipo        text not null default 'setor_indicado',
  setor_id    text references public.iol_setores (id) on delete set null,
  autor_id    uuid references public.perfis (id) on delete set null,
  autor_nome  text,
  itens       int not null default 0,
  unidades    int not null default 0,
  dados       jsonb,
  criado_em   timestamptz not null default now(),
  lida_em     timestamptz
);
create index notificacoes_usuario_idx on public.notificacoes (usuario_id, criado_em desc);
create index notificacoes_nao_lidas_idx on public.notificacoes (usuario_id) where lida_em is null;
create index notificacoes_setor_idx on public.notificacoes (setor_id);
create index notificacoes_autor_idx on public.notificacoes (autor_id);
alter table public.notificacoes enable row level security;
create policy notif_select on public.notificacoes for select to authenticated using (usuario_id = (select auth.uid()));
create policy notif_update on public.notificacoes for update to authenticated
  using (usuario_id = (select auth.uid())) with check (usuario_id = (select auth.uid()));
revoke all on public.notificacoes from anon, authenticated;
grant select on public.notificacoes to authenticated;
grant update (lida_em) on public.notificacoes to authenticated;

-- 3) Geração: depois de cada lote de lançamentos, avisa quem atua no setor indicado (menos quem lançou)
create or replace function private.notificar_indicacao()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  with x as (
    select distinct on (n.setor_destino_id, n.criado_por, n.item_id)
           n.setor_destino_id, n.criado_por, n.autor_nome, n.motivo_id, i.quantidade, i.setor_id
      from novos n join public.iol_itens i on i.id = n.item_id
     where n.setor_informado
  ),
  g as (
    select x.setor_destino_id, x.criado_por, max(x.autor_nome) as autor_nome, count(*)::int as itens,
           coalesce(sum(x.quantidade), 0)::int as unidades,
           (select coalesce(jsonb_agg(distinct s2.nome), '[]'::jsonb) from public.iol_setores s2
             where s2.id in (select x2.setor_id from x x2 where x2.setor_destino_id = x.setor_destino_id and x2.criado_por is not distinct from x.criado_por)) as origens,
           (select coalesce(jsonb_agg(distinct m2.nome), '[]'::jsonb) from public.iol_motivos m2
             where m2.id in (select x2.motivo_id from x x2 where x2.setor_destino_id = x.setor_destino_id and x2.criado_por is not distinct from x.criado_por)) as motivos
      from x group by x.setor_destino_id, x.criado_por
  )
  insert into public.notificacoes (usuario_id, tipo, setor_id, autor_id, autor_nome, itens, unidades, dados)
  select p.id, 'setor_indicado', g.setor_destino_id, g.criado_por, g.autor_nome, g.itens, g.unidades,
         jsonb_build_object('origens', g.origens, 'motivos', g.motivos)
    from g
    join public.perfis p on p.setor_id = g.setor_destino_id
                        and p.papel in ('operador', 'gestor', 'admin')
                        and p.id is distinct from g.criado_por;
  return null;
end;
$$;
revoke all on function private.notificar_indicacao() from public, anon, authenticated;
create trigger notificar_indicacao after insert on public.iol_lancamentos
  referencing new table as novos for each statement execute function private.notificar_indicacao();

-- 4) Leitura e marcação como lida (apenas as próprias)
create or replace function public.notif_listar(p_limite int default 30)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'nao_lidas', (select count(*)::int from public.notificacoes n where n.usuario_id = (select auth.uid()) and n.lida_em is null),
    'itens', coalesce((select jsonb_agg(to_jsonb(r)) from (
        select n.id, n.tipo, n.setor_id, s.nome as setor_nome, n.autor_nome, n.itens, n.unidades, n.dados, n.criado_em, n.lida_em
          from public.notificacoes n left join public.iol_setores s on s.id = n.setor_id
         where n.usuario_id = (select auth.uid())
         order by n.criado_em desc, n.id desc limit least(greatest(p_limite, 1), 100)) r), '[]'::jsonb));
$$;

create or replace function public.notif_marcar(p_ids bigint[] default null)
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare v_n int;
begin
  update public.notificacoes set lida_em = now()
   where usuario_id = (select auth.uid()) and lida_em is null and (p_ids is null or id = any (p_ids));
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.notif_listar(int), public.notif_marcar(bigint[]) from public, anon;
grant execute on function public.notif_listar(int), public.notif_marcar(bigint[]) to authenticated;
