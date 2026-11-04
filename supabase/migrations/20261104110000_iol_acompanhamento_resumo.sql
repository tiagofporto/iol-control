-- Acompanhamento: totais por setor do item e por setor indicado para tratar, com os mesmos filtros da lista.
-- Cada item conta uma vez por grupo (mesmo que tenha várias justificativas); unidades = soma das quantidades desses itens.
create or replace function public.iol_acompanhamento_resumo(
  p_desde timestamptz default null, p_setor text default null, p_dest text default null, p_sit text default null,
  p_motivo bigint default null, p_vigentes boolean default true, p_busca text default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with b as (
    select h.* from public.iol_lancamentos_hist h
     where (p_desde is null or h.criado_em >= p_desde)
       and (p_sit is null or p_sit = '' or (p_sit = 'em' and h.resolvido_em is null) or (p_sit = 'saiu' and h.resolvido_em is not null))
       and (p_motivo is null or h.motivo_id = p_motivo)
       and (p_vigentes is not true or h.vigente)
       and (nullif(btrim(p_busca), '') is null or (
             h.sku ilike '%' || replace(replace(replace(btrim(p_busca), '\', '\\'), '%', '\%'), '_', '\_') || '%'
          or h.container ilike '%' || replace(replace(replace(btrim(p_busca), '\', '\\'), '%', '\%'), '_', '\_') || '%'
          or h.autor_nome ilike '%' || replace(replace(replace(btrim(p_busca), '\', '\\'), '%', '\%'), '_', '\_') || '%'
          or h.observacao ilike '%' || replace(replace(replace(btrim(p_busca), '\', '\\'), '%', '\%'), '_', '\_') || '%'))
  ),
  a as (  -- por setor do item (respeita o filtro de setor indicado)
    select distinct on (h.setor_id, h.item_id) h.setor_id as k, h.setor_nome as nome, h.quantidade, h.resolvido_em
      from b h where p_dest is null or p_dest = '' or (h.setor_informado and h.setor_destino_id = p_dest)
     order by h.setor_id, h.item_id
  ),
  d as (  -- por setor indicado para tratar (respeita o filtro de setor do item); null = indicação não informada
    select distinct on (case when h.setor_informado then h.setor_destino_id end, h.item_id)
           case when h.setor_informado then h.setor_destino_id end as k,
           case when h.setor_informado then h.setor_destino_nome end as nome, h.quantidade, h.resolvido_em
      from b h where p_setor is null or p_setor = '' or h.setor_id = p_setor
     order by case when h.setor_informado then h.setor_destino_id end, h.item_id
  ),
  t as (  -- total com todos os filtros
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
revoke execute on function public.iol_acompanhamento_resumo(timestamptz, text, text, text, bigint, boolean, text) from public, anon;
grant execute on function public.iol_acompanhamento_resumo(timestamptz, text, text, text, bigint, boolean, text) to authenticated;
