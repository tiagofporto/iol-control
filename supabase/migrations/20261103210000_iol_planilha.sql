-- Justificativas em lote por planilha: valida (p_gravar = false) ou grava (p_gravar = true) linhas do modelo Excel.
-- Cada linha identifica o item por FcSku (+ contêiner e setor opcionais) e traz motivo, observação, previsão e setor que deve tratar.
create or replace function public.iol_lancar_planilha(p_linhas jsonb, p_gravar boolean default false)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_res jsonb;
begin
  if jsonb_typeof(p_linhas) is distinct from 'array' then
    raise exception 'Formato inválido';
  end if;
  if jsonb_array_length(p_linhas) > 5000 then
    raise exception 'Máximo de 5.000 linhas por envio';
  end if;

  with l as (
    select * from jsonb_to_recordset(p_linhas) as x(linha int, sku text, container text, setor text, motivo text, observacao text, previsao text, tratar text)
  ),
  v as (
    select l.*, m.id as motivo_id, sd.id as dest_id,
      case
        when btrim(coalesce(l.sku, '')) = '' then 'FcSku vazio'
        when m.id is null then 'Motivo não reconhecido (use um da lista)'
        when m.exige_observacao and btrim(coalesce(l.observacao, '')) = '' then 'Observação obrigatória para este motivo'
        when coalesce(l.previsao, '') <> '' and l.previsao !~ '^\d{4}-\d{2}-\d{2}$' then 'Previsão inválida (use dd/mm/aaaa)'
        when btrim(coalesce(l.tratar, '')) <> '' and sd.id is null then 'Setor que deve tratar não reconhecido (use um da lista)'
      end as erro
    from l
    left join public.iol_motivos m on m.ativo and lower(btrim(m.nome)) = lower(btrim(l.motivo))
    left join public.iol_setores sd on lower(sd.id) = lower(btrim(l.tratar)) or lower(btrim(sd.nome)) = lower(btrim(l.tratar))
  ),
  it as (
    select v.linha, i.id as item_id
    from v
    join public.iol_itens i
      on i.resolvido_em is null
     and upper(i.sku) = upper(btrim(v.sku))
     and (btrim(coalesce(v.container, '')) = '' or upper(i.container) = upper(btrim(v.container)))
     and (btrim(coalesce(v.setor, '')) = ''
          or lower(i.setor_id) = lower(btrim(v.setor))
          or exists (select 1 from public.iol_setores s where s.id = i.setor_id and lower(btrim(s.nome)) = lower(btrim(v.setor))))
    where v.erro is null
  ),
  itd as (   -- um item citado em mais de uma linha: vale a última
    select distinct on (it.item_id) it.item_id, v.motivo_id, v.observacao, v.previsao, v.dest_id
    from it join v on v.linha = it.linha
    order by it.item_id, it.linha desc
  ),
  ins as (
    insert into public.iol_lancamentos (item_id, motivo_id, observacao, previsao_resolucao, setor_destino_id)
    select item_id, motivo_id, nullif(btrim(observacao), ''), nullif(previsao, '')::date, dest_id
      from itd
     where p_gravar
    returning item_id
  )
  select jsonb_build_object(
    'linhas', (select count(*) from l),
    'itens', (select count(*) from itd),
    'gravados', (select count(*) from ins),
    'erros', coalesce((select jsonb_agg(jsonb_build_object('linha', linha, 'erro', erro) order by linha) from v where erro is not null), '[]'::jsonb),
    'nao_encontradas', coalesce((select jsonb_agg(jsonb_build_object('linha', linha, 'sku', sku, 'container', container) order by linha)
                                  from v where erro is null and not exists (select 1 from it where it.linha = v.linha)), '[]'::jsonb))
  into v_res;
  return v_res;
end;
$$;
revoke execute on function public.iol_lancar_planilha(jsonb, boolean) from public, anon;
grant execute on function public.iol_lancar_planilha(jsonb, boolean) to authenticated;
