-- =============================================================================
-- IOL Manager — schema inicial
-- Gestão de itens parados no FC (IOL), com histórico imutável de justificativas.
--
-- Como aplicar: Supabase Dashboard → SQL Editor → colar este arquivo → Run
-- (ou `supabase db push` se estiver usando o CLI).
--
-- Modelo de acesso (tabela public.perfis):
--   pendente  → acabou de criar conta; não enxerga nada até um admin aprovar
--   operador  → vê tudo e registra justificativas
--   gestor    → operador + importa bases
--   admin     → gestor + configurações, motivos e papéis dos usuários
-- O primeiro usuário cadastrado vira admin automaticamente.
-- =============================================================================

create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

-- -----------------------------------------------------------------------------
-- Perfis e papéis
-- -----------------------------------------------------------------------------
create table public.perfis (
  id        uuid primary key references auth.users (id) on delete cascade,
  nome      text not null default '',
  email     text,
  papel     text not null default 'pendente'
            check (papel in ('pendente', 'operador', 'gestor', 'admin')),
  criado_em timestamptz not null default now()
);

-- Papel do usuário logado. SECURITY DEFINER para ler perfis sem recursão de RLS;
-- fica no schema "private" (não exposto na Data API).
create or replace function private.papel_atual()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.papel from public.perfis p where p.id = (select auth.uid());
$$;
revoke all on function private.papel_atual() from public, anon;
grant execute on function private.papel_atual() to authenticated;

-- Cria o perfil ao cadastrar um usuário. O primeiro vira admin; os demais ficam pendentes.
-- (raw_user_meta_data é usado só para exibir o nome, nunca para autorização.)
create or replace function private.criar_perfil()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.perfis (id, nome, email, papel)
  values (
    new.id,
    coalesce(nullif(btrim(new.raw_user_meta_data ->> 'nome'), ''), split_part(new.email, '@', 1)),
    new.email,
    case when exists (select 1 from public.perfis) then 'pendente' else 'admin' end
  );
  return new;
end;
$$;
revoke all on function private.criar_perfil() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.criar_perfil();

-- -----------------------------------------------------------------------------
-- Cadastros: setores, motivos e limites de dias
-- -----------------------------------------------------------------------------
create table public.iol_setores (
  id    text primary key,                 -- nome do arquivo em minúsculas (ex.: 'inbound')
  nome  text not null,
  ordem int  not null default 0,
  ativo boolean not null default true
);

create table public.iol_motivos (
  id               bigint generated always as identity primary key,
  nome             text not null unique,
  exige_observacao boolean not null default false,
  ordem            int not null default 0,
  ativo            boolean not null default true
);

-- Linha única: limites em dias (a partir de 0,5 aparece; ≥3 alerta; ≥5 crítico)
create table public.iol_config (
  id          boolean primary key default true check (id),
  dia_minimo  numeric(5, 2) not null default 0.5,
  dia_alerta  numeric(5, 2) not null default 3,
  dia_critico numeric(5, 2) not null default 5,
  check (dia_minimo > 0 and dia_minimo <= dia_alerta and dia_alerta <= dia_critico)
);

-- -----------------------------------------------------------------------------
-- Importações (uma por setor por upload) e itens
-- -----------------------------------------------------------------------------
create table public.iol_importacoes (
  id               bigint generated always as identity primary key,
  setor_id         text not null references public.iol_setores (id),
  referencia_em    timestamptz not null,           -- data/hora a que a planilha se refere
  arquivo_nome     text,
  status           text not null default 'em_andamento'
                   check (status in ('em_andamento', 'concluida')),
  linhas           int not null default 0,
  unidades         int not null default 0,
  itens_novos      int not null default 0,
  itens_reabertos  int not null default 0,
  itens_resolvidos int not null default 0,
  itens_ativos     int not null default 0,         -- ≥ dia_minimo no momento da importação
  itens_alerta     int not null default 0,
  itens_criticos   int not null default 0,
  criado_por       uuid references public.perfis (id) on delete set null default auth.uid(),
  criado_em        timestamptz not null default now()
);
create index iol_importacoes_setor_ref_idx on public.iol_importacoes (setor_id, referencia_em desc);
create index iol_importacoes_criado_por_idx on public.iol_importacoes (criado_por);

-- Um item = setor + SKU + contêiner + disposição + proprietário.
-- Reaparecer numa nova planilha atualiza o tempo parado; sumir da planilha marca como resolvido.
create table public.iol_itens (
  id                   bigint generated always as identity primary key,
  chave                text not null unique,
  setor_id             text not null references public.iol_setores (id),
  sku                  text not null,
  container            text not null default '',
  container_tipo       text,
  local_atual          text,
  local_tipo           text,
  area                 text,
  area_tipo            text,
  disposicao           text not null default '',
  proprietario         text not null default '',
  quantidade           int  not null default 1,
  idle_ms              bigint not null,
  dias                 numeric(10, 3) generated always as (idle_ms::numeric / 86400000) stored,
  primeiro_visto_em    timestamptz not null,
  ultimo_visto_em      timestamptz not null,
  ultima_importacao_id bigint references public.iol_importacoes (id),
  reaberto_em          timestamptz,
  resolvido_em         timestamptz,
  -- cache da justificativa vigente (mantido por trigger; o histórico fica em iol_lancamentos)
  motivo_atual_id      bigint references public.iol_motivos (id),
  justificado_em       timestamptz,
  ultimo_lancamento_id bigint
);
create index iol_itens_ativos_dias_idx  on public.iol_itens (dias desc)             where resolvido_em is null;
create index iol_itens_ativos_setor_idx on public.iol_itens (setor_id, dias desc)   where resolvido_em is null;
create index iol_itens_importacao_idx   on public.iol_itens (ultima_importacao_id);
create index iol_itens_motivo_idx       on public.iol_itens (motivo_atual_id);

-- Histórico de lançamentos: somente inserção (sem UPDATE/DELETE para ninguém).
create table public.iol_lancamentos (
  id                 bigint generated always as identity primary key,
  item_id            bigint not null references public.iol_itens (id) on delete restrict,
  motivo_id          bigint not null references public.iol_motivos (id),
  observacao         text check (char_length(observacao) <= 1000),
  previsao_resolucao date,
  dias_no_lancamento numeric(10, 3),               -- dias parado no momento do lançamento
  autor_nome         text,
  criado_por         uuid references auth.users (id) on delete set null default auth.uid(),
  criado_em          timestamptz not null default now()
);
create index iol_lancamentos_item_idx   on public.iol_lancamentos (item_id, criado_em desc);
create index iol_lancamentos_motivo_idx on public.iol_lancamentos (motivo_id);
create index iol_lancamentos_autor_idx  on public.iol_lancamentos (criado_por);
create index iol_lancamentos_criado_idx on public.iol_lancamentos (criado_em desc);

-- Valida e completa o lançamento (autor, dias parado, observação obrigatória).
create or replace function private.lancamento_antes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item   public.iol_itens;
  v_motivo public.iol_motivos;
begin
  select * into v_item from public.iol_itens where id = new.item_id;
  if not found then
    raise exception 'Item % não existe', new.item_id;
  end if;
  if v_item.resolvido_em is not null then
    raise exception 'O item % já saiu do IOL e não aceita novos lançamentos', new.item_id;
  end if;

  select * into v_motivo from public.iol_motivos where id = new.motivo_id;
  if not found or not v_motivo.ativo then
    raise exception 'Motivo inválido ou inativo';
  end if;
  new.observacao := nullif(btrim(coalesce(new.observacao, '')), '');
  if v_motivo.exige_observacao and new.observacao is null then
    raise exception 'O motivo "%" exige uma observação', v_motivo.nome;
  end if;

  new.criado_por         := (select auth.uid());
  new.autor_nome         := (select p.nome from public.perfis p where p.id = (select auth.uid()));
  new.dias_no_lancamento := v_item.dias;
  new.criado_em          := now();
  return new;
end;
$$;
revoke all on function private.lancamento_antes() from public, anon, authenticated;

create trigger iol_lancamentos_before
  before insert on public.iol_lancamentos
  for each row execute function private.lancamento_antes();

-- Atualiza o cache de justificativa vigente no item (SECURITY DEFINER: operadores não têm UPDATE em iol_itens).
create or replace function private.lancamento_depois()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.iol_itens
     set motivo_atual_id      = new.motivo_id,
         justificado_em       = new.criado_em,
         ultimo_lancamento_id = new.id
   where id = new.item_id;
  return new;
end;
$$;
revoke all on function private.lancamento_depois() from public, anon, authenticated;

create trigger iol_lancamentos_after
  after insert on public.iol_lancamentos
  for each row execute function private.lancamento_depois();

-- -----------------------------------------------------------------------------
-- Views (security_invoker: respeitam o RLS de quem consulta)
-- -----------------------------------------------------------------------------
create view public.iol_itens_ativos
with (security_invoker = true) as
select
  i.id, i.setor_id, s.nome as setor_nome,
  i.sku, i.container, i.container_tipo, i.local_atual, i.local_tipo, i.area,
  i.disposicao, i.proprietario, i.quantidade, i.idle_ms, i.dias,
  i.primeiro_visto_em, i.ultimo_visto_em, i.reaberto_em,
  i.motivo_atual_id, m.nome as motivo_nome, i.justificado_em,
  case
    when i.dias >= c.dia_critico then 'critico'
    when i.dias >= c.dia_alerta  then 'alerta'
    when i.dias >= c.dia_minimo  then 'atencao'
    else 'abaixo'
  end as faixa
from public.iol_itens i
join public.iol_setores s on s.id = i.setor_id
cross join public.iol_config c
left join public.iol_motivos m on m.id = i.motivo_atual_id
where i.resolvido_em is null;

create view public.iol_lancamentos_hist
with (security_invoker = true) as
select
  l.id, l.item_id, l.motivo_id, m.nome as motivo_nome,
  l.observacao, l.previsao_resolucao, l.dias_no_lancamento,
  l.autor_nome, l.criado_por, l.criado_em,
  i.setor_id, s.nome as setor_nome, i.sku, i.container, i.quantidade,
  i.dias as dias_atual, i.resolvido_em,
  (l.id = i.ultimo_lancamento_id) as vigente
from public.iol_lancamentos l
join public.iol_itens   i on i.id = l.item_id
join public.iol_setores s on s.id = i.setor_id
join public.iol_motivos m on m.id = l.motivo_id;

-- -----------------------------------------------------------------------------
-- Funções (RPC) — todas SECURITY INVOKER: o RLS vale para quem chama
-- -----------------------------------------------------------------------------

-- 1/3 — abre uma importação para um setor
create or replace function public.iol_importacao_iniciar(
  p_setor text, p_referencia timestamptz, p_arquivo text default null)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare v_id bigint;
begin
  if exists (
    select 1 from public.iol_importacoes
     where setor_id = p_setor and status = 'concluida' and referencia_em > p_referencia
  ) then
    raise exception 'Já existe uma importação mais recente para o setor "%". Use uma data de referência posterior.', p_setor;
  end if;

  insert into public.iol_importacoes (setor_id, referencia_em, arquivo_nome)
  values (p_setor, p_referencia, p_arquivo)
  returning id into v_id;
  return v_id;
end;
$$;

-- 2/3 — recebe um lote de linhas (o app envia em blocos de ~2.000) e faz upsert
create or replace function public.iol_importacao_lote(p_importacao bigint, p_linhas jsonb)
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_setor text;
  v_ref   timestamptz;
  v_n     int;
begin
  select setor_id, referencia_em into v_setor, v_ref
    from public.iol_importacoes
   where id = p_importacao and status = 'em_andamento';
  if not found then
    raise exception 'Importação % não existe ou já foi concluída', p_importacao;
  end if;

  insert into public.iol_itens as t (
    chave, setor_id, sku, container, container_tipo, local_atual, local_tipo, area, area_tipo,
    disposicao, proprietario, quantidade, idle_ms,
    primeiro_visto_em, ultimo_visto_em, ultima_importacao_id)
  select distinct on (k.chave)
    k.chave, v_setor, k.sku, k.container, k.container_tipo, k.local_atual, k.local_tipo, k.area, k.area_tipo,
    k.disposicao, k.proprietario, k.quantidade, k.idle_ms, v_ref, v_ref, p_importacao
  from (
    select
      v_setor || '|' || btrim(x.sku) || '|' || coalesce(x.container, '') || '|'
        || coalesce(x.disposicao, '') || '|' || coalesce(x.proprietario, '') as chave,
      btrim(x.sku) as sku,
      coalesce(x.container, '') as container,
      x.container_tipo, x.local_atual, x.local_tipo, x.area, x.area_tipo,
      coalesce(x.disposicao, '') as disposicao,
      coalesce(x.proprietario, '') as proprietario,
      greatest(coalesce(x.quantidade, 1), 1) as quantidade,
      x.idle_ms
    from jsonb_to_recordset(p_linhas) as x(
      sku text, container text, container_tipo text, local_atual text, local_tipo text,
      area text, area_tipo text, disposicao text, proprietario text, quantidade int, idle_ms bigint)
    where x.sku is not null and btrim(x.sku) <> '' and x.idle_ms is not null
  ) k
  order by k.chave, k.idle_ms desc
  on conflict (chave) do update set
    container_tipo       = excluded.container_tipo,
    local_atual          = excluded.local_atual,
    local_tipo           = excluded.local_tipo,
    area                 = excluded.area,
    area_tipo            = excluded.area_tipo,
    quantidade           = excluded.quantidade,
    idle_ms              = excluded.idle_ms,
    ultimo_visto_em      = excluded.ultimo_visto_em,
    ultima_importacao_id = excluded.ultima_importacao_id,
    -- voltou depois de resolvido: novo ciclo, justificativa anterior deixa de valer (fica no histórico)
    reaberto_em          = case when t.resolvido_em is not null then excluded.ultimo_visto_em else t.reaberto_em end,
    motivo_atual_id      = case when t.resolvido_em is not null then null else t.motivo_atual_id end,
    justificado_em       = case when t.resolvido_em is not null then null else t.justificado_em end,
    ultimo_lancamento_id = case when t.resolvido_em is not null then null else t.ultimo_lancamento_id end,
    resolvido_em         = null
  where t.ultimo_visto_em <= excluded.ultimo_visto_em;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- 3/3 — fecha a importação: itens do setor que não vieram na planilha saem do IOL
create or replace function public.iol_importacao_finalizar(p_importacao bigint)
returns public.iol_importacoes
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v         public.iol_importacoes;
  c         public.iol_config;
  v_resolv  int;
begin
  select * into v from public.iol_importacoes
   where id = p_importacao and status = 'em_andamento'
   for update;
  if not found then
    raise exception 'Importação % não existe ou já foi concluída', p_importacao;
  end if;
  select * into c from public.iol_config;

  update public.iol_itens
     set resolvido_em = v.referencia_em
   where setor_id = v.setor_id
     and resolvido_em is null
     and ultima_importacao_id is distinct from p_importacao
     and ultimo_visto_em < v.referencia_em;
  get diagnostics v_resolv = row_count;

  update public.iol_importacoes im
     set status           = 'concluida',
         itens_resolvidos = v_resolv,
         linhas           = s.linhas,
         unidades         = s.unidades,
         itens_novos      = s.novos,
         itens_reabertos  = s.reabertos,
         itens_ativos     = s.ativos,
         itens_alerta     = s.alerta,
         itens_criticos   = s.criticos
    from (
      select count(*)::int                                                       as linhas,
             coalesce(sum(i.quantidade), 0)::int                                 as unidades,
             count(*) filter (where i.primeiro_visto_em = v.referencia_em)::int  as novos,
             count(*) filter (where i.reaberto_em = v.referencia_em)::int        as reabertos,
             count(*) filter (where i.dias >= c.dia_minimo)::int                 as ativos,
             count(*) filter (where i.dias >= c.dia_alerta and i.dias < c.dia_critico)::int as alerta,
             count(*) filter (where i.dias >= c.dia_critico)::int                as criticos
        from public.iol_itens i
       where i.ultima_importacao_id = p_importacao
    ) s
   where im.id = p_importacao
  returning im.* into v;

  return v;
end;
$$;

-- Lança a mesma justificativa para vários itens de uma vez (itens já resolvidos são ignorados)
create or replace function public.iol_lancar(
  p_itens bigint[], p_motivo bigint, p_observacao text default null, p_previsao date default null)
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare v_n int;
begin
  if coalesce(array_length(p_itens, 1), 0) = 0 then
    return 0;
  end if;
  if array_length(p_itens, 1) > 5000 then
    raise exception 'Máximo de 5.000 itens por lançamento';
  end if;

  insert into public.iol_lancamentos (item_id, motivo_id, observacao, previsao_resolucao)
  select i.id, p_motivo, p_observacao, p_previsao
    from public.iol_itens i
   where i.id = any (p_itens) and i.resolvido_em is null;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

-- Painel: totais, quebra por setor/motivo e tendência (último snapshot de cada setor por dia)
create or replace function public.iol_painel()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with a as (
    select * from public.iol_itens_ativos where faixa <> 'abaixo'
  )
  select jsonb_build_object(
    'totais', (
      select jsonb_build_object(
        'itens',              count(*),
        'unidades',           coalesce(sum(quantidade), 0),
        'atencao',            count(*) filter (where faixa = 'atencao'),
        'alerta',             count(*) filter (where faixa = 'alerta'),
        'criticos',           count(*) filter (where faixa = 'critico'),
        'sem_justificativa',  count(*) filter (where motivo_atual_id is null),
        'criticos_sem_just',  count(*) filter (where faixa = 'critico' and motivo_atual_id is null)
      ) from a),
    'por_setor', (
      select coalesce(jsonb_agg(r order by r.criticos desc, r.itens desc, r.ordem), '[]'::jsonb)
        from (
          select s.id, s.nome, s.ordem,
                 count(a.id)                                         as itens,
                 coalesce(sum(a.quantidade), 0)                      as unidades,
                 count(a.id) filter (where a.faixa = 'alerta')       as alerta,
                 count(a.id) filter (where a.faixa = 'critico')      as criticos,
                 count(a.id) filter (where a.motivo_atual_id is null) as sem_justificativa
            from public.iol_setores s
            left join a on a.setor_id = s.id
           where s.ativo
           group by s.id, s.nome, s.ordem
        ) r),
    'por_motivo', (
      select coalesce(jsonb_agg(r order by r.itens desc), '[]'::jsonb)
        from (
          select coalesce(a.motivo_nome, 'Sem justificativa') as nome,
                 count(*) as itens, coalesce(sum(a.quantidade), 0) as unidades
            from a group by 1
        ) r),
    'tendencia', (
      select coalesce(jsonb_agg(t order by t.dia), '[]'::jsonb)
        from (
          select d.dia,
                 sum(d.itens_ativos)::int   as ativos,
                 sum(d.itens_alerta)::int   as alerta,
                 sum(d.itens_criticos)::int as criticos
            from (
              select distinct on (dia, im.setor_id)
                     (im.referencia_em at time zone 'America/Sao_Paulo')::date as dia,
                     im.setor_id, im.itens_ativos, im.itens_alerta, im.itens_criticos
                from public.iol_importacoes im
               where im.status = 'concluida'
                 and im.referencia_em > now() - interval '30 days'
               order by dia, im.setor_id, im.referencia_em desc
            ) d
           group by d.dia
        ) t),
    'ultima_importacao', (select max(referencia_em) from public.iol_importacoes where status = 'concluida')
  );
$$;

-- -----------------------------------------------------------------------------
-- Row Level Security
-- -----------------------------------------------------------------------------
alter table public.perfis          enable row level security;
alter table public.iol_setores     enable row level security;
alter table public.iol_motivos     enable row level security;
alter table public.iol_config      enable row level security;
alter table public.iol_importacoes enable row level security;
alter table public.iol_itens       enable row level security;
alter table public.iol_lancamentos enable row level security;

-- perfis: cada um vê o seu; gestor/admin veem todos; só admin altera
create policy perfis_select on public.perfis for select to authenticated
  using (id = (select auth.uid()) or (select private.papel_atual()) in ('gestor', 'admin'));
create policy perfis_update_admin on public.perfis for update to authenticated
  using ((select private.papel_atual()) = 'admin')
  with check ((select private.papel_atual()) = 'admin');

-- cadastros: leitura para quem tem acesso; escrita só admin
create policy setores_select on public.iol_setores for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy setores_admin_ins on public.iol_setores for insert to authenticated
  with check ((select private.papel_atual()) = 'admin');
create policy setores_admin_upd on public.iol_setores for update to authenticated
  using ((select private.papel_atual()) = 'admin')
  with check ((select private.papel_atual()) = 'admin');

create policy motivos_select on public.iol_motivos for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy motivos_admin_ins on public.iol_motivos for insert to authenticated
  with check ((select private.papel_atual()) = 'admin');
create policy motivos_admin_upd on public.iol_motivos for update to authenticated
  using ((select private.papel_atual()) = 'admin')
  with check ((select private.papel_atual()) = 'admin');

create policy config_select on public.iol_config for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy config_admin_upd on public.iol_config for update to authenticated
  using ((select private.papel_atual()) = 'admin')
  with check ((select private.papel_atual()) = 'admin');

-- importações e itens: leitura para todos com acesso; escrita para gestor/admin
create policy importacoes_select on public.iol_importacoes for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy importacoes_ins on public.iol_importacoes for insert to authenticated
  with check ((select private.papel_atual()) in ('gestor', 'admin'));
create policy importacoes_upd on public.iol_importacoes for update to authenticated
  using ((select private.papel_atual()) in ('gestor', 'admin'))
  with check ((select private.papel_atual()) in ('gestor', 'admin'));

create policy itens_select on public.iol_itens for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy itens_ins on public.iol_itens for insert to authenticated
  with check ((select private.papel_atual()) in ('gestor', 'admin'));
create policy itens_upd on public.iol_itens for update to authenticated
  using ((select private.papel_atual()) in ('gestor', 'admin'))
  with check ((select private.papel_atual()) in ('gestor', 'admin'));

-- lançamentos: todos com acesso leem e inserem; ninguém altera ou apaga
create policy lancamentos_select on public.iol_lancamentos for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy lancamentos_ins on public.iol_lancamentos for insert to authenticated
  with check ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));

-- -----------------------------------------------------------------------------
-- Grants explícitos (a Data API não expõe tabelas novas automaticamente)
-- -----------------------------------------------------------------------------
revoke all on public.perfis, public.iol_setores, public.iol_motivos, public.iol_config,
              public.iol_importacoes, public.iol_itens, public.iol_lancamentos,
              public.iol_itens_ativos, public.iol_lancamentos_hist
  from anon, authenticated;

grant select on public.perfis, public.iol_setores, public.iol_motivos, public.iol_config,
                public.iol_importacoes, public.iol_itens, public.iol_lancamentos,
                public.iol_itens_ativos, public.iol_lancamentos_hist
  to authenticated;
grant update (nome, papel) on public.perfis to authenticated;
grant insert, update on public.iol_setores, public.iol_motivos to authenticated;
grant update on public.iol_config to authenticated;
grant insert, update on public.iol_importacoes, public.iol_itens to authenticated;
grant insert on public.iol_lancamentos to authenticated;

revoke execute on function
  public.iol_importacao_iniciar(text, timestamptz, text),
  public.iol_importacao_lote(bigint, jsonb),
  public.iol_importacao_finalizar(bigint),
  public.iol_lancar(bigint[], bigint, text, date),
  public.iol_painel()
  from public, anon;
grant execute on function
  public.iol_importacao_iniciar(text, timestamptz, text),
  public.iol_importacao_lote(bigint, jsonb),
  public.iol_importacao_finalizar(bigint),
  public.iol_lancar(bigint[], bigint, text, date),
  public.iol_painel()
  to authenticated;

-- -----------------------------------------------------------------------------
-- Dados iniciais (editáveis depois pelo admin no app)
-- -----------------------------------------------------------------------------
insert into public.iol_config (id) values (true);

insert into public.iol_setores (id, nome, ordem) values
  ('inbound',          'Inbound',            1),
  ('transshipment',    'Transshipment',      2),
  ('outbound',         'Outbound',           3),
  ('problemsolve',     'Problem Solve',      4),
  ('pendingresearch',  'Pending Research',   5),
  ('reverselogistics', 'Reverse Logistics',  6),
  ('unsellables',      'Unsellables',        7),
  ('unsellableremoval','Unsellable Removal', 8),
  ('pendingrepair',    'Pending Repair',     9),
  ('reverserepair',    'Reverse Repair',    10),
  ('largeadjustment',  'Large Adjustment',  11),
  ('unknown',          'Unknown',           12);

insert into public.iol_motivos (nome, exige_observacao, ordem) values
  ('Aguardando armazenagem',                 false, 1),
  ('Em investigação / pesquisa',             false, 2),
  ('Divergência de inventário em análise',   false, 3),
  ('Item avariado, aguardando destino',      false, 4),
  ('Aguardando transferência / envio',       false, 5),
  ('Devolução / logística reversa em curso', false, 6),
  ('Contêiner não localizado',               false, 7),
  ('Sem espaço de armazenagem',              false, 8),
  ('Problema de cadastro do ASIN',           false, 9),
  ('Outro (descrever)',                      true, 10);
