-- Quem justifica pode indicar qual setor deve tratar o item. Se não indicar, vale o setor já vinculado ao item.
alter table public.iol_lancamentos
  add column setor_destino_id text references public.iol_setores (id),
  add column setor_informado boolean not null default false;
create index iol_lancamentos_setor_destino_idx on public.iol_lancamentos (setor_destino_id);

-- lançamentos antigos: setor vinculado ao item, sem indicação do usuário
update public.iol_lancamentos l set setor_destino_id = i.setor_id from public.iol_itens i where i.id = l.item_id and l.setor_destino_id is null;

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

  -- setor indicado pelo usuário; sem indicação, mantém o setor vinculado ao item
  new.setor_informado := new.setor_destino_id is not null;
  new.setor_destino_id := coalesce(new.setor_destino_id, v_item.setor_id);

  new.criado_por         := (select auth.uid());
  new.autor_nome         := (select p.nome from public.perfis p where p.id = (select auth.uid()));
  new.dias_no_lancamento := v_item.dias;
  new.criado_em          := now();
  return new;
end;
$$;
revoke all on function private.lancamento_antes() from public, anon, authenticated;

drop function if exists public.iol_lancar(bigint[], bigint, text, date);
create or replace function public.iol_lancar(
  p_itens bigint[], p_motivo bigint, p_observacao text default null, p_previsao date default null, p_setor text default null)
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
  if p_setor is not null and not exists (select 1 from public.iol_setores where id = p_setor) then
    raise exception 'Setor inválido';
  end if;

  insert into public.iol_lancamentos (item_id, motivo_id, observacao, previsao_resolucao, setor_destino_id)
  select i.id, p_motivo, p_observacao, p_previsao, nullif(p_setor, '')
    from public.iol_itens i
   where i.id = any (p_itens) and i.resolvido_em is null;

  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke execute on function public.iol_lancar(bigint[], bigint, text, date, text) from public, anon;
grant execute on function public.iol_lancar(bigint[], bigint, text, date, text) to authenticated;

create or replace view public.iol_lancamentos_hist
with (security_invoker = true) as
select
  l.id, l.item_id, l.motivo_id, m.nome as motivo_nome,
  l.observacao, l.previsao_resolucao, l.dias_no_lancamento,
  l.autor_nome, l.criado_por, l.criado_em,
  i.setor_id, s.nome as setor_nome, i.sku, i.container, i.quantidade,
  i.dias as dias_atual, i.resolvido_em,
  (l.id = i.ultimo_lancamento_id) as vigente,
  l.setor_destino_id, sd.nome as setor_destino_nome, l.setor_informado
from public.iol_lancamentos l
join public.iol_itens   i on i.id = l.item_id
join public.iol_setores s on s.id = i.setor_id
join public.iol_motivos m on m.id = l.motivo_id
left join public.iol_setores sd on sd.id = l.setor_destino_id;

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
  inv.nome as item_nome,
  ul.setor_destino_id as tratar_setor_id,
  sd.nome as tratar_setor_nome,
  coalesce(ul.setor_informado, false) as tratar_informado
from public.iol_itens i
join public.iol_setores s on s.id = i.setor_id
cross join public.iol_config c
left join public.iol_motivos m on m.id = i.motivo_atual_id
left join public.iol_rodeo_vinculo v on v.item_id = i.id
left join public.inventario_sku inv on inv.fcsku = i.sku
left join public.iol_lancamentos ul on ul.id = i.ultimo_lancamento_id
left join public.iol_setores sd on sd.id = ul.setor_destino_id
where i.resolvido_em is null;

grant select on public.iol_itens_ativos, public.iol_lancamentos_hist to authenticated;
revoke all on public.iol_itens_ativos, public.iol_lancamentos_hist from anon;
