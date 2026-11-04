-- Comparativo por faixa de dias parados (0,5 a <1 · 1 a 2 · 3 a 4 · 5+), em itens e em unidades.
-- Faixas: f1 = dias < 1 · f2 = 1 <= dias < 3 · f3 = 3 <= dias < 5 · f4 = dias >= 5 (dias no momento em que o item saiu/chegou).

create or replace function private.faixa_dias(p_dias numeric)
returns text
language sql
immutable
set search_path = ''
as $$ select case when p_dias < 1 then 'f1' when p_dias < 3 then 'f2' when p_dias < 5 then 'f3' else 'f4' end; $$;
revoke all on function private.faixa_dias(numeric) from public, anon;
grant execute on function private.faixa_dias(numeric) to authenticated;

create or replace function public.iol_comparativo_resumo(p_ref timestamptz, p_min numeric default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with c as (select coalesce(p_min, dia_minimo) as mn from public.iol_config),
  base as (
    select g.setor_id, g.tipo, i.quantidade, i.dias, i.motivo_atual_id
      from public.iol_movimentos g
      join public.iol_itens i on i.id = g.item_id
      join c on i.dias >= c.mn
     where g.referencia_em = p_ref
  ),
  mov as (
    select setor_id,
           count(*) filter (where tipo = 'novo')::int as novos,
           count(*) filter (where tipo = 'reaberto')::int as reabertos,
           count(*) filter (where tipo = 'resolvido')::int as resolvidos,
           coalesce(sum(quantidade) filter (where tipo = 'resolvido'), 0)::int as resolvidos_unidades,
           count(*) filter (where tipo = 'resolvido' and motivo_atual_id is not null)::int as resolvidos_justificados
      from base group by setor_id
  ),
  fx as (
    select tipo, setor_id, private.faixa_dias(dias) as k, count(*)::int as itens, coalesce(sum(quantidade), 0)::int as unidades
      from base group by 1, 2, 3
  ),
  b as (select * from public.iol_importacoes where referencia_em = p_ref and status = 'concluida'),
  s as (
    select b.setor_id, st.nome, st.ordem, b.itens_ativos as ativos, b.itens_criticos as criticos,
           p.itens_ativos as ant_ativos, p.itens_criticos as ant_criticos, p.referencia_em as ant_ref,
           coalesce(m.novos, 0) as novos, coalesce(m.reabertos, 0) as reabertos, coalesce(m.resolvidos, 0) as resolvidos,
           coalesce(m.resolvidos_unidades, 0) as resolvidos_unidades,
           coalesce(m.resolvidos_justificados, 0) as resolvidos_justificados
      from b
      join public.iol_setores st on st.id = b.setor_id
      left join lateral (select * from public.iol_importacoes x
                          where x.setor_id = b.setor_id and x.status = 'concluida' and x.referencia_em < p_ref
                          order by x.referencia_em desc limit 1) p on true
      left join mov m on m.setor_id = b.setor_id
  )
  select jsonb_build_object(
    'referencia_em', p_ref,
    'novos',        coalesce((select sum(novos) from s), 0),
    'reabertos',    coalesce((select sum(reabertos) from s), 0),
    'resolvidos',   coalesce((select sum(resolvidos) from s), 0),
    'resolvidos_unidades', coalesce((select sum(resolvidos_unidades) from s), 0),
    'resolvidos_justificados', coalesce((select sum(resolvidos_justificados) from s), 0),
    'ativos',       coalesce((select sum(ativos) from s), 0),
    'criticos',     coalesce((select sum(criticos) from s), 0),
    'ant_ativos',   (select sum(ant_ativos) from s),
    'ant_criticos', (select sum(ant_criticos) from s),
    'setores_sem_anterior', (select count(*) from s where ant_ref is null),
    'por_setor', coalesce((select jsonb_agg(to_jsonb(s) order by s.ordem) from s), '[]'::jsonb),
    'faixas',    coalesce((select jsonb_agg(to_jsonb(fx)) from fx where setor_id in (select setor_id from s)), '[]'::jsonb)
  );
$$;

drop function if exists public.iol_comparativo_itens(timestamptz, text, text, int, int, numeric);
create or replace function public.iol_comparativo_itens(
  p_ref timestamptz, p_tipo text default null, p_setor text default null,
  p_limit int default 50, p_offset int default 0, p_min numeric default null, p_faixa text default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with c as (select coalesce(p_min, dia_minimo) as mn from public.iol_config),
  x as (
    select i.id, i.setor_id, st.nome as setor_nome, i.sku, i.container, i.local_atual, i.disposicao, i.quantidade, i.dias,
           i.motivo_atual_id, m.nome as motivo_nome, inv.asin, inv.nome as item_nome,
           g.tipo, private.faixa_dias(i.dias) as faixa
      from public.iol_movimentos g
      join public.iol_itens i on i.id = g.item_id
      join c on i.dias >= c.mn
      join public.iol_setores st on st.id = i.setor_id
      left join public.iol_motivos m on m.id = i.motivo_atual_id
      left join public.inventario_sku inv on inv.fcsku = i.sku
     where g.referencia_em = p_ref
       and (p_setor is null or i.setor_id = p_setor)
  ),
  f as (select * from x where (p_tipo is null or tipo = p_tipo) and (p_faixa is null or faixa = p_faixa))
  select jsonb_build_object(
    'total', (select count(*) from f),
    'unidades', (select coalesce(sum(quantidade), 0) from f),
    'rows', coalesce((select jsonb_agg(to_jsonb(r)) from (
        select * from f order by dias desc, id limit greatest(p_limit, 1) offset greatest(p_offset, 0)) r), '[]'::jsonb));
$$;
revoke execute on function public.iol_comparativo_itens(timestamptz, text, text, int, int, numeric, text) from public, anon;
grant execute on function public.iol_comparativo_itens(timestamptz, text, text, int, int, numeric, text) to authenticated;
