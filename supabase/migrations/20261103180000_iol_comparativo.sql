-- Comparativo a cada atualização do IOL: o que chegou (novo), voltou (reaberto) e saiu (resolvido).
-- Uma "atualização" = todas as planilhas com a mesma data de referência. Por padrão só conta itens >= dia_minimo.
-- Cada importação grava seus movimentos; assim o comparativo continua correto mesmo se o item voltar depois.

create table public.iol_movimentos (
  id             bigint generated always as identity primary key,
  item_id        bigint not null references public.iol_itens (id) on delete cascade,
  setor_id       text not null,
  referencia_em  timestamptz not null,
  tipo           text not null check (tipo in ('novo', 'reaberto', 'resolvido')),
  unique (item_id, referencia_em, tipo)
);
create index iol_movimentos_ref_idx on public.iol_movimentos (referencia_em, tipo);
alter table public.iol_movimentos enable row level security;
create policy mov_select on public.iol_movimentos for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy mov_ins on public.iol_movimentos for insert to authenticated
  with check ((select private.papel_atual()) in ('gestor', 'admin'));
revoke all on public.iol_movimentos from anon, authenticated;
grant select on public.iol_movimentos to authenticated;
grant insert on public.iol_movimentos to authenticated;

-- histórico já existente (melhor esforço, a partir das datas guardadas nos itens)
insert into public.iol_movimentos (item_id, setor_id, referencia_em, tipo)
  select id, setor_id, primeiro_visto_em, 'novo' from public.iol_itens
  union all select id, setor_id, reaberto_em, 'reaberto' from public.iol_itens where reaberto_em is not null
  union all select id, setor_id, resolvido_em, 'resolvido' from public.iol_itens where resolvido_em is not null
  on conflict do nothing;

create or replace function public.iol_importacao_finalizar(p_importacao bigint)
returns public.iol_importacoes
language plpgsql
security invoker
set search_path = ''
as $f$
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

  with r as (
    update public.iol_itens
       set resolvido_em = v.referencia_em
     where setor_id = v.setor_id
       and resolvido_em is null
       and ultima_importacao_id is distinct from p_importacao
       and ultimo_visto_em < v.referencia_em
    returning id
  )
  insert into public.iol_movimentos (item_id, setor_id, referencia_em, tipo)
    select id, v.setor_id, v.referencia_em, 'resolvido' from r on conflict do nothing;
  get diagnostics v_resolv = row_count;

  insert into public.iol_movimentos (item_id, setor_id, referencia_em, tipo)
    select id, setor_id, v.referencia_em, case when reaberto_em = v.referencia_em then 'reaberto' else 'novo' end
      from public.iol_itens
     where ultima_importacao_id = p_importacao and (primeiro_visto_em = v.referencia_em or reaberto_em = v.referencia_em)
    on conflict do nothing;

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
$f$;

create or replace function public.iol_comparativo_datas()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(d order by d.referencia_em desc), '[]'::jsonb)
    from (select referencia_em, count(*)::int as setores, sum(linhas)::int as linhas
            from public.iol_importacoes where status = 'concluida'
           group by referencia_em order by referencia_em desc limit 40) d;
$$;

create or replace function public.iol_comparativo_resumo(p_ref timestamptz, p_min numeric default null)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with c as (select coalesce(p_min, dia_minimo) as mn from public.iol_config),
  mov as (
    select g.setor_id,
           count(*) filter (where g.tipo = 'novo')::int as novos,
           count(*) filter (where g.tipo = 'reaberto')::int as reabertos,
           count(*) filter (where g.tipo = 'resolvido')::int as resolvidos,
           count(*) filter (where g.tipo = 'resolvido' and i.motivo_atual_id is not null)::int as resolvidos_justificados
      from public.iol_movimentos g
      join public.iol_itens i on i.id = g.item_id
      join c on i.dias >= c.mn
     where g.referencia_em = p_ref
     group by g.setor_id
  ),
  b as (select * from public.iol_importacoes where referencia_em = p_ref and status = 'concluida'),
  s as (
    select b.setor_id, st.nome, st.ordem, b.itens_ativos as ativos, b.itens_criticos as criticos,
           p.itens_ativos as ant_ativos, p.itens_criticos as ant_criticos, p.referencia_em as ant_ref,
           coalesce(m.novos, 0) as novos, coalesce(m.reabertos, 0) as reabertos, coalesce(m.resolvidos, 0) as resolvidos,
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
    'resolvidos_justificados', coalesce((select sum(resolvidos_justificados) from s), 0),
    'ativos',       coalesce((select sum(ativos) from s), 0),
    'criticos',     coalesce((select sum(criticos) from s), 0),
    'ant_ativos',   (select sum(ant_ativos) from s),
    'ant_criticos', (select sum(ant_criticos) from s),
    'setores_sem_anterior', (select count(*) from s where ant_ref is null),
    'por_setor', coalesce((select jsonb_agg(to_jsonb(s) order by s.ordem) from s), '[]'::jsonb)
  );
$$;

create or replace function public.iol_comparativo_itens(
  p_ref timestamptz, p_tipo text default null, p_setor text default null,
  p_limit int default 50, p_offset int default 0, p_min numeric default null)
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
           g.tipo
      from public.iol_movimentos g
      join public.iol_itens i on i.id = g.item_id
      join c on i.dias >= c.mn
      join public.iol_setores st on st.id = i.setor_id
      left join public.iol_motivos m on m.id = i.motivo_atual_id
      left join public.inventario_sku inv on inv.fcsku = i.sku
     where g.referencia_em = p_ref
       and (p_setor is null or i.setor_id = p_setor)
  ),
  f as (select * from x where p_tipo is null or tipo = p_tipo)
  select jsonb_build_object(
    'total', (select count(*) from f),
    'rows', coalesce((select jsonb_agg(to_jsonb(r)) from (
        select * from f order by dias desc, id limit greatest(p_limit, 1) offset greatest(p_offset, 0)) r), '[]'::jsonb));
$$;

revoke execute on function public.iol_comparativo_datas(), public.iol_comparativo_resumo(timestamptz, numeric),
  public.iol_comparativo_itens(timestamptz, text, text, int, int, numeric) from public, anon;
grant execute on function public.iol_comparativo_datas(), public.iol_comparativo_resumo(timestamptz, numeric),
  public.iol_comparativo_itens(timestamptz, text, text, int, int, numeric) to authenticated;
