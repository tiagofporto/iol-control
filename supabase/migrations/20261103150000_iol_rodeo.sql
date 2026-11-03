-- =============================================================================
-- Cruzamento IOL × Rodeo × Inventário
--  * inventario_sku: tradutor FcSku → FNSKU/ASIN (vem do Inventário Geral do FC)
--  * rodeo_linhas:   foto atual da lista de envios do Rodeo
--  * iol_rodeo_vinculo: por item em IOL, com o que o Rodeo tem ligado a ele
--    Vínculo por CONTÊINER (mesmo Scannable ID) e/ou por PRODUTO (FcSku → FNSKU/ASIN = FN SKU do Rodeo)
--  * Tudo que está como CROSSDOCK no Rodeo é considerado do setor IXD.
-- =============================================================================

create table public.base_importacoes (
  id             bigint generated always as identity primary key,
  tipo           text not null check (tipo in ('rodeo', 'inventario')),
  arquivo_nome   text,
  referencia_em  timestamptz not null,
  status         text not null default 'em_andamento' check (status in ('em_andamento', 'concluida')),
  linhas         int not null default 0,
  itens_vinculados int not null default 0,
  criado_por     uuid references public.perfis (id) on delete set null default auth.uid(),
  criado_em      timestamptz not null default now()
);
create index base_importacoes_tipo_idx on public.base_importacoes (tipo, referencia_em desc);
create index base_importacoes_criado_por_idx on public.base_importacoes (criado_por);

create table public.inventario_sku (
  fcsku          text primary key,
  fnsku          text,
  asin           text,
  importacao_id  bigint references public.base_importacoes (id) on delete set null,
  atualizado_em  timestamptz not null default now()
);
create index inventario_sku_fnsku_idx on public.inventario_sku (fnsku);
create index inventario_sku_asin_idx on public.inventario_sku (asin);
create index inventario_sku_importacao_idx on public.inventario_sku (importacao_id);

create table public.rodeo_linhas (
  id                 bigint generated always as identity primary key,
  importacao_id      bigint not null references public.base_importacoes (id) on delete cascade,
  transfer_id        text,
  destino            text,
  fn_sku             text not null,
  titulo             text,
  enviar_ate         timestamp,
  process_path       text,
  prioridade         text,
  scannable_id       text,
  container_tipo     text,
  outer_scannable_id text,
  status             text not null default '',
  quantidade         int not null default 1,
  work_pool          text,
  dwell_horas        numeric(10, 2),
  ixd                boolean generated always as (upper(status) = 'CROSSDOCK' or upper(coalesce(work_pool, '')) = 'CROSSDOCK') stored
);
create index rodeo_linhas_importacao_idx on public.rodeo_linhas (importacao_id);
create index rodeo_linhas_fnsku_idx on public.rodeo_linhas (fn_sku);
create index rodeo_linhas_scannable_idx on public.rodeo_linhas (scannable_id);

create table public.iol_rodeo_vinculo (
  item_id        bigint primary key references public.iol_itens (id) on delete cascade,
  tipo           text not null check (tipo in ('conteiner', 'asin', 'ambos')),
  linhas         int not null,
  unidades       int not null,
  destinos       text,
  status         text,
  work_pools     text,
  dwell_max      numeric(10, 2),
  ixd            boolean not null default false,
  atualizado_em  timestamptz not null default now()
);
create index iol_rodeo_vinculo_ixd_idx on public.iol_rodeo_vinculo (ixd);

-- Recalcula os vínculos dos itens em IOL com a foto atual do Rodeo.
-- Eficiente: o Rodeo é agregado por FN SKU uma única vez; só as linhas do mesmo contêiner (poucas) são cruzadas item a item.
create or replace function public.iol_rodeo_recalcular()
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_imp  bigint;
  v_n    int;
begin
  select max(id) into v_imp from public.base_importacoes where tipo = 'rodeo' and status = 'concluida';
  delete from public.iol_rodeo_vinculo where true;
  if v_imp is null then
    return jsonb_build_object('vinculados', 0);
  end if;

  with l as (
    select fn_sku, scannable_id, destino, status, work_pool, quantidade, dwell_horas, ixd
      from public.rodeo_linhas where importacao_id = v_imp
  ),
  rf as (
    select fn_sku,
           count(*)::int as linhas,
           coalesce(sum(quantidade), 0)::int as un,
           array_agg(distinct destino) filter (where destino is not null) as destinos,
           array_agg(distinct status) as sts,
           array_agg(distinct work_pool) filter (where work_pool is not null) as wps,
           max(dwell_horas) as dw,
           bool_or(ixd) as ixd
      from l group by fn_sku
  ),
  it as (
    select id as item_id, sku, container from public.iol_itens where resolvido_em is null
  ),
  chaves as (
    select it.item_id, s.fnsku as k from it join public.inventario_sku s on s.fcsku = it.sku where s.fnsku is not null
    union
    select it.item_id, s.asin   from it join public.inventario_sku s on s.fcsku = it.sku where s.asin is not null
  ),
  a_src as (
    select c.item_id, rf.linhas, rf.un, rf.destinos, rf.sts, rf.wps, rf.dw, rf.ixd, false as cont, true as asn
      from chaves c join rf on rf.fn_sku = c.k
  ),
  c_src as (
    -- linhas do mesmo contêiner; as que também casam por produto já estão contadas em a_src
    select it.item_id,
           (count(*) filter (where x.extra))::int as linhas,
           coalesce(sum(x.quantidade) filter (where x.extra), 0)::int as un,
           array_agg(distinct x.destino) filter (where x.extra and x.destino is not null) as destinos,
           array_agg(distinct x.status) filter (where x.extra) as sts,
           array_agg(distinct x.work_pool) filter (where x.extra and x.work_pool is not null) as wps,
           max(x.dwell_horas) filter (where x.extra) as dw,
           coalesce(bool_or(x.ixd) filter (where x.extra), false) as ixd,
           true as cont, false as asn
      from it
      join lateral (
        select l.*, (l.fn_sku is distinct from s.fnsku and l.fn_sku is distinct from s.asin) as extra
          from l left join public.inventario_sku s on s.fcsku = it.sku
         where l.scannable_id = it.container
      ) x on it.container <> ''
     group by it.item_id
  ),
  src as (
    select * from a_src union all select * from c_src
  ),
  tot as (
    select item_id,
           case when bool_or(cont) and bool_or(asn) then 'ambos' when bool_or(cont) then 'conteiner' else 'asin' end as tipo,
           sum(linhas)::int as linhas, sum(un)::int as un, max(dw) as dw, bool_or(ixd) as ixd
      from src group by item_id
  ),
  d as (select item_id, string_agg(distinct x, ', ' order by x) as t from (select item_id, unnest(destinos) as x from src) z group by item_id),
  s2 as (select item_id, string_agg(distinct x, ', ' order by x) as t from (select item_id, unnest(sts) as x from src) z group by item_id),
  w as (select item_id, string_agg(distinct x, ', ' order by x) as t from (select item_id, unnest(wps) as x from src) z group by item_id)
  insert into public.iol_rodeo_vinculo (item_id, tipo, linhas, unidades, destinos, status, work_pools, dwell_max, ixd)
  select t.item_id, t.tipo, t.linhas, t.un, d.t, s2.t, w.t, t.dw, coalesce(t.ixd, false)
    from tot t
    left join d on d.item_id = t.item_id
    left join s2 on s2.item_id = t.item_id
    left join w on w.item_id = t.item_id;
  get diagnostics v_n = row_count;
  return jsonb_build_object('vinculados', v_n);
end;
$$;

-- Importação das bases de cruzamento (mesmo fluxo em 3 passos da importação de IOL)
create or replace function public.base_importacao_iniciar(p_tipo text, p_arquivo text, p_referencia timestamptz)
returns bigint
language plpgsql
security invoker
set search_path = ''
as $$
declare v_id bigint;
begin
  insert into public.base_importacoes (tipo, arquivo_nome, referencia_em)
  values (p_tipo, p_arquivo, p_referencia) returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.rodeo_importacao_lote(p_importacao bigint, p_linhas jsonb)
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare v_n int;
begin
  if not exists (select 1 from public.base_importacoes where id = p_importacao and tipo = 'rodeo' and status = 'em_andamento') then
    raise exception 'Importação % não existe ou já foi concluída', p_importacao;
  end if;
  insert into public.rodeo_linhas (importacao_id, transfer_id, destino, fn_sku, titulo, enviar_ate, process_path, prioridade,
                                   scannable_id, container_tipo, outer_scannable_id, status, quantidade, work_pool, dwell_horas)
  select p_importacao, x.transfer_id, x.destino, btrim(x.fn_sku), x.titulo, x.enviar_ate, x.process_path, x.prioridade,
         x.scannable_id, x.container_tipo, x.outer_scannable_id, coalesce(x.status, ''), greatest(coalesce(x.quantidade, 1), 0),
         x.work_pool, x.dwell_horas
    from jsonb_to_recordset(p_linhas) as x(
      transfer_id text, destino text, fn_sku text, titulo text, enviar_ate timestamp, process_path text, prioridade text,
      scannable_id text, container_tipo text, outer_scannable_id text, status text, quantidade int, work_pool text, dwell_horas numeric)
   where x.fn_sku is not null and btrim(x.fn_sku) <> '';
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.inventario_importacao_lote(p_importacao bigint, p_linhas jsonb)
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare v_n int;
begin
  if not exists (select 1 from public.base_importacoes where id = p_importacao and tipo = 'inventario' and status = 'em_andamento') then
    raise exception 'Importação % não existe ou já foi concluída', p_importacao;
  end if;
  insert into public.inventario_sku as t (fcsku, fnsku, asin, importacao_id, atualizado_em)
  select distinct on (x.fcsku) btrim(x.fcsku), nullif(btrim(x.fnsku), ''), nullif(btrim(x.asin), ''), p_importacao, now()
    from jsonb_to_recordset(p_linhas) as x(fcsku text, fnsku text, asin text)
   where x.fcsku is not null and btrim(x.fcsku) <> ''
   order by x.fcsku
  on conflict (fcsku) do update
    set fnsku = excluded.fnsku, asin = excluded.asin, importacao_id = excluded.importacao_id, atualizado_em = excluded.atualizado_em;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

create or replace function public.base_importacao_finalizar(p_importacao bigint)
returns public.base_importacoes
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v public.base_importacoes;
  v_linhas int;
  v_vinc   int;
begin
  select * into v from public.base_importacoes where id = p_importacao and status = 'em_andamento' for update;
  if not found then
    raise exception 'Importação % não existe ou já foi concluída', p_importacao;
  end if;

  if v.tipo = 'rodeo' then
    select count(*)::int into v_linhas from public.rodeo_linhas where importacao_id = p_importacao;
  else
    select count(*)::int into v_linhas from public.inventario_sku where importacao_id = p_importacao;
  end if;

  update public.base_importacoes set status = 'concluida', linhas = v_linhas where id = p_importacao;

  if v.tipo = 'rodeo' then
    -- o Rodeo é sempre a foto mais recente: some a anterior
    delete from public.rodeo_linhas where importacao_id <> p_importacao;
  end if;

  perform public.iol_rodeo_recalcular();
  select count(*)::int into v_vinc from public.iol_rodeo_vinculo;
  update public.base_importacoes set itens_vinculados = v_vinc where id = p_importacao returning * into v;
  return v;
end;
$$;

-- View de itens ativos passa a trazer os dados do Rodeo (colunas novas no fim)
create or replace view public.iol_itens_ativos
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
  end as faixa,
  v.tipo       as rodeo_tipo,
  v.linhas     as rodeo_linhas,
  v.unidades   as rodeo_unidades,
  v.destinos   as rodeo_destinos,
  v.status     as rodeo_status,
  v.work_pools as rodeo_work_pools,
  v.dwell_max  as rodeo_dwell_max,
  coalesce(v.ixd, false) as rodeo_ixd,
  case when coalesce(v.ixd, false) then 'ixd' else i.setor_id end as setor_efetivo_id,
  case when coalesce(v.ixd, false) then 'IXD' else s.nome end as setor_efetivo_nome
from public.iol_itens i
join public.iol_setores s on s.id = i.setor_id
cross join public.iol_config c
left join public.iol_motivos m on m.id = i.motivo_atual_id
left join public.iol_rodeo_vinculo v on v.item_id = i.id
where i.resolvido_em is null;

-- Resumo para a tela Rodeo
create or replace function public.iol_rodeo_resumo()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with a as (select * from public.iol_itens_ativos where faixa <> 'abaixo'),
  r as (select * from a where rodeo_tipo is not null)
  select jsonb_build_object(
    'itens_ligados',      (select count(*) from r),
    'unidades_ligadas',   (select coalesce(sum(quantidade), 0) from r),
    'ixd',                (select count(*) from r where rodeo_ixd),
    'por_conteiner',      (select count(*) from r where rodeo_tipo in ('conteiner', 'ambos')),
    'criticos_ligados',   (select count(*) from r where faixa = 'critico'),
    'alerta_ligados',     (select count(*) from r where faixa = 'alerta'),
    'sem_justificativa',  (select count(*) from r where motivo_atual_id is null),
    'total_iol',          (select count(*) from a),
    'sem_inventario',     (select count(*) from a where not exists (select 1 from public.inventario_sku s where s.fcsku = a.sku)),
    'rodeo_linhas',       (select count(*) from public.rodeo_linhas),
    'inventario_skus',    (select count(*) from public.inventario_sku),
    'rodeo_em',           (select max(referencia_em) from public.base_importacoes where tipo = 'rodeo' and status = 'concluida'),
    'inventario_em',      (select max(referencia_em) from public.base_importacoes where tipo = 'inventario' and status = 'concluida'),
    'por_destino', (select coalesce(jsonb_agg(d order by d.itens desc), '[]'::jsonb) from (
        select x as destino, count(*) as itens
          from r, lateral unnest(string_to_array(r.rodeo_destinos, ', ')) as x
         group by x order by 2 desc limit 30) d),
    'por_setor', (select coalesce(jsonb_agg(d order by d.itens desc), '[]'::jsonb) from (
        select setor_efetivo_id as id, setor_efetivo_nome as nome, count(*) as itens, count(*) filter (where faixa = 'critico') as criticos
          from r group by 1, 2) d)
  );
$$;

-- RLS
alter table public.base_importacoes   enable row level security;
alter table public.inventario_sku     enable row level security;
alter table public.rodeo_linhas       enable row level security;
alter table public.iol_rodeo_vinculo  enable row level security;

create policy base_imp_select on public.base_importacoes for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy base_imp_ins on public.base_importacoes for insert to authenticated
  with check ((select private.papel_atual()) in ('gestor', 'admin'));
create policy base_imp_upd on public.base_importacoes for update to authenticated
  using ((select private.papel_atual()) in ('gestor', 'admin'))
  with check ((select private.papel_atual()) in ('gestor', 'admin'));

create policy inv_select on public.inventario_sku for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy inv_ins on public.inventario_sku for insert to authenticated
  with check ((select private.papel_atual()) in ('gestor', 'admin'));
create policy inv_upd on public.inventario_sku for update to authenticated
  using ((select private.papel_atual()) in ('gestor', 'admin'))
  with check ((select private.papel_atual()) in ('gestor', 'admin'));

create policy rodeo_select on public.rodeo_linhas for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy rodeo_ins on public.rodeo_linhas for insert to authenticated
  with check ((select private.papel_atual()) in ('gestor', 'admin'));
create policy rodeo_del on public.rodeo_linhas for delete to authenticated
  using ((select private.papel_atual()) in ('gestor', 'admin'));

create policy vinculo_select on public.iol_rodeo_vinculo for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy vinculo_ins on public.iol_rodeo_vinculo for insert to authenticated
  with check ((select private.papel_atual()) in ('gestor', 'admin'));
create policy vinculo_del on public.iol_rodeo_vinculo for delete to authenticated
  using ((select private.papel_atual()) in ('gestor', 'admin'));

-- Grants explícitos
revoke all on public.base_importacoes, public.inventario_sku, public.rodeo_linhas, public.iol_rodeo_vinculo from anon, authenticated;
grant select on public.base_importacoes, public.inventario_sku, public.rodeo_linhas, public.iol_rodeo_vinculo to authenticated;
grant insert, update on public.base_importacoes, public.inventario_sku to authenticated;
grant insert, delete on public.rodeo_linhas, public.iol_rodeo_vinculo to authenticated;
revoke all on public.iol_itens_ativos from anon;
grant select on public.iol_itens_ativos to authenticated;

revoke execute on function
  public.iol_rodeo_recalcular(),
  public.base_importacao_iniciar(text, text, timestamptz),
  public.rodeo_importacao_lote(bigint, jsonb),
  public.inventario_importacao_lote(bigint, jsonb),
  public.base_importacao_finalizar(bigint),
  public.iol_rodeo_resumo()
  from public, anon;
grant execute on function
  public.iol_rodeo_recalcular(),
  public.base_importacao_iniciar(text, text, timestamptz),
  public.rodeo_importacao_lote(bigint, jsonb),
  public.inventario_importacao_lote(bigint, jsonb),
  public.base_importacao_finalizar(bigint),
  public.iol_rodeo_resumo()
  to authenticated;
