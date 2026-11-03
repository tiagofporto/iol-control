-- Valores disponíveis para os filtros por coluna (local externo, disposição, tipo de contêiner),
-- com a contagem de itens, respeitando dias, setor, justificativa e busca. SECURITY INVOKER: vale o RLS.
create or replace function public.iol_facetas(
  p_min numeric default 0, p_max numeric default null, p_setor text default null,
  p_motivo text default null, p_busca text default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with b as (
    select a.local_atual, a.disposicao, a.container_tipo
      from public.iol_itens_ativos a
     where a.dias >= coalesce(p_min, 0)
       and (p_max is null or a.dias < p_max)
       and (coalesce(p_setor, '') = '' or a.setor_id = p_setor)
       and case
             when coalesce(p_motivo, '') = '' then true
             when p_motivo = 'sem' then a.motivo_atual_id is null
             else a.motivo_atual_id = p_motivo::bigint
           end
       and (coalesce(p_busca, '') = ''
            or a.sku ilike '%' || p_busca || '%'
            or a.container ilike '%' || p_busca || '%'
            or a.local_atual ilike '%' || p_busca || '%')
  )
  select jsonb_build_object(
    'local', (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n) order by n desc, v), '[]'::jsonb)
                from (select local_atual as v, count(*) as n from b
                       where coalesce(local_atual, '') <> '' group by 1 order by 2 desc, 1 limit 100) x),
    'disp',  (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n) order by n desc, v), '[]'::jsonb)
                from (select disposicao as v, count(*) as n from b
                       where coalesce(disposicao, '') <> '' group by 1 order by 2 desc, 1 limit 100) x),
    'ctipo', (select coalesce(jsonb_agg(jsonb_build_object('v', v, 'n', n) order by n desc, v), '[]'::jsonb)
                from (select container_tipo as v, count(*) as n from b
                       where coalesce(container_tipo, '') <> '' group by 1 order by 2 desc, 1 limit 100) x)
  );
$$;
revoke execute on function public.iol_facetas(numeric, numeric, text, text, text) from public, anon;
grant execute on function public.iol_facetas(numeric, numeric, text, text, text) to authenticated;
