-- ASIN e nome do item (vêm do Inventário Geral) nas listas de itens
alter table public.inventario_sku add column if not exists nome text;

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
  insert into public.inventario_sku as t (fcsku, fnsku, asin, nome, importacao_id, atualizado_em)
  select distinct on (x.fcsku) btrim(x.fcsku), nullif(btrim(x.fnsku), ''), nullif(btrim(x.asin), ''), nullif(btrim(x.nome), ''), p_importacao, now()
    from jsonb_to_recordset(p_linhas) as x(fcsku text, fnsku text, asin text, nome text)
   where x.fcsku is not null and btrim(x.fcsku) <> ''
   order by x.fcsku
  on conflict (fcsku) do update
    set fnsku = excluded.fnsku, asin = excluded.asin, nome = excluded.nome, importacao_id = excluded.importacao_id, atualizado_em = excluded.atualizado_em;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

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
  case when coalesce(v.ixd, false) then 'IXD' else s.nome end as setor_efetivo_nome,
  inv.asin as asin,
  inv.nome as item_nome
from public.iol_itens i
join public.iol_setores s on s.id = i.setor_id
cross join public.iol_config c
left join public.iol_motivos m on m.id = i.motivo_atual_id
left join public.iol_rodeo_vinculo v on v.item_id = i.id
left join public.inventario_sku inv on inv.fcsku = i.sku
where i.resolvido_em is null;

grant select on public.iol_itens_ativos to authenticated;
revoke all on public.iol_itens_ativos from anon;
