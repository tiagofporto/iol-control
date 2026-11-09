-- Acompanhamento: filtro "indicados a outro setor" (itens do meu setor que indiquei para outro setor tratar).
-- indicado_outro = a justificativa informou um setor de tratamento diferente do setor do item.
-- Acompanhamento: ASIN e nome do item (vindos do Inventário) no histórico de lançamentos e na busca.
create or replace view public.iol_lancamentos_hist
with (security_invoker = true) as
select
  l.id, l.item_id, l.motivo_id, m.nome as motivo_nome,
  l.observacao, l.previsao_resolucao, l.dias_no_lancamento,
  l.autor_nome, l.criado_por, l.criado_em,
  i.setor_id, s.nome as setor_nome, i.sku, i.container, i.quantidade,
  i.dias as dias_atual, i.resolvido_em,
  (l.id = i.ultimo_lancamento_id) as vigente,
  l.setor_destino_id, sd.nome as setor_destino_nome, l.setor_informado,
  inv.asin, inv.nome as item_nome,
  (l.setor_informado and l.setor_destino_id is distinct from i.setor_id) as indicado_outro
from public.iol_lancamentos l
join public.iol_itens   i on i.id = l.item_id
join public.iol_setores s on s.id = i.setor_id
join public.iol_motivos m on m.id = l.motivo_id
left join public.iol_setores sd on sd.id = l.setor_destino_id
left join public.inventario_sku inv on inv.fcsku = i.sku;

drop function if exists public.iol_acompanhamento_resumo(timestamptz, text, text, text, bigint, boolean, text);
create or replace function public.iol_acompanhamento_resumo(
  p_desde timestamptz default null, p_setor text default null, p_dest text default null, p_sit text default null,
  p_motivo bigint default null, p_vigentes boolean default true, p_busca text default null, p_outro boolean default false)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with q as (select '%' || replace(replace(replace(btrim(coalesce(p_busca, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%' as t, nullif(btrim(coalesce(p_busca, '')), '') as b),
  b as (
    select h.* from public.iol_lancamentos_hist h, q
     where (p_desde is null or h.criado_em >= p_desde)
       and (p_sit is null or p_sit = '' or (p_sit = 'em' and h.resolvido_em is null) or (p_sit = 'saiu' and h.resolvido_em is not null))
       and (p_motivo is null or h.motivo_id = p_motivo)
       and (p_vigentes is not true or h.vigente)
       and (p_outro is not true or h.indicado_outro)
       and (q.b is null or h.sku ilike q.t or h.container ilike q.t or h.autor_nome ilike q.t or h.observacao ilike q.t or h.asin ilike q.t or h.item_nome ilike q.t)
  ),
  a as (
    select distinct on (h.setor_id, h.item_id) h.setor_id as k, h.setor_nome as nome, h.quantidade, h.resolvido_em
      from b h where p_dest is null or p_dest = '' or (h.setor_informado and h.setor_destino_id = p_dest)
     order by h.setor_id, h.item_id
  ),
  d as (
    select distinct on (case when h.setor_informado then h.setor_destino_id end, h.item_id)
           case when h.setor_informado then h.setor_destino_id end as k,
           case when h.setor_informado then h.setor_destino_nome end as nome, h.quantidade, h.resolvido_em
      from b h where p_setor is null or p_setor = '' or h.setor_id = p_setor
     order by case when h.setor_informado then h.setor_destino_id end, h.item_id
  ),
  t as (
    select distinct on (h.item_id) h.quantidade, h.resolvido_em
      from b h
     where (p_setor is null or p_setor = '' or h.setor_id = p_setor)
       and (p_dest is null or p_dest = '' or (h.setor_informado and h.setor_destino_id = p_dest))
     order by h.item_id
  )
  select jsonb_build_object(
    'por_setor', coalesce((select jsonb_agg(to_jsonb(g) order by g.unidades desc, g.nome) from (
        select k, nome, count(*)::int as itens, coalesce(sum(quantidade), 0)::int as unidades,
               count(*) filter (where resolvido_em is not null)::int as itens_saiu,
               coalesce(sum(quantidade) filter (where resolvido_em is not null), 0)::int as unidades_saiu
          from a group by k, nome) g), '[]'::jsonb),
    'por_destino', coalesce((select jsonb_agg(to_jsonb(g) order by g.k is null, g.unidades desc, g.nome) from (
        select k, nome, count(*)::int as itens, coalesce(sum(quantidade), 0)::int as unidades,
               count(*) filter (where resolvido_em is not null)::int as itens_saiu,
               coalesce(sum(quantidade) filter (where resolvido_em is not null), 0)::int as unidades_saiu
          from d group by k, nome) g), '[]'::jsonb),
    'total', (select jsonb_build_object('itens', count(*)::int, 'unidades', coalesce(sum(quantidade), 0)::int,
               'itens_saiu', count(*) filter (where resolvido_em is not null)::int,
               'unidades_saiu', coalesce(sum(quantidade) filter (where resolvido_em is not null), 0)::int) from t));
$$;
revoke execute on function public.iol_acompanhamento_resumo(timestamptz, text, text, text, bigint, boolean, text, boolean) from public, anon;
grant execute on function public.iol_acompanhamento_resumo(timestamptz, text, text, text, bigint, boolean, text, boolean) to authenticated;
