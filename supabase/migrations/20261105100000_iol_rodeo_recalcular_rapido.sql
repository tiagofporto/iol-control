-- Rodeo: o recálculo dos vínculos estourava o tempo (504) com listas grandes (~28 mil linhas × ~36 mil itens em IOL).
-- Causa: a CTE "l" era materializada (usada 2x) e o cruzamento por contêiner varria a lista inteira para cada item.
-- "not materialized" deixa o planejador usar o índice rodeo_linhas_scannable_idx.
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

  with l as not materialized (
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
