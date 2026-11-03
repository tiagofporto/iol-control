-- Procurar itens perdidos (PROCV): lista de códigos procurados + registro de TUDO que foi bipado.
-- Código procurado pode ser contêiner, FcSku ou ASIN. A base consultada é o IOL atual (com ASIN vindo do Inventário).

create index if not exists iol_itens_container_up_idx on public.iol_itens (upper(container));
create index if not exists iol_itens_sku_up_idx on public.iol_itens (upper(sku));
create index if not exists inventario_sku_asin_up_idx on public.inventario_sku (upper(asin));

create table public.procura_itens (
  id               bigint generated always as identity primary key,
  codigo           text not null check (codigo = upper(codigo) and char_length(codigo) between 3 and 80),
  tipo             text not null,
  criado_por       uuid references public.perfis (id) on delete set null default auth.uid(),
  autor_nome       text,
  criado_em        timestamptz not null default now(),
  localizado_em    timestamptz,
  localizado_por   uuid references public.perfis (id) on delete set null,
  localizado_nome  text,
  localizado_no    text,
  arquivado_em     timestamptz
);
create unique index procura_itens_ativo_uk on public.procura_itens (codigo) where arquivado_em is null;
create index procura_itens_criado_por_idx on public.procura_itens (criado_por);
create index procura_itens_localizado_por_idx on public.procura_itens (localizado_por);

-- Registro de leituras: somente inserção, feita apenas pela função de bipagem.
create table public.procura_leituras (
  id           bigint generated always as identity primary key,
  codigo       text not null,
  resultado    text not null check (resultado in ('localizado', 'ja_localizado', 'fora_da_lista')),
  marcados     text,
  info         jsonb,
  usuario_id   uuid references public.perfis (id) on delete set null,
  usuario_nome text,
  criado_em    timestamptz not null default now()
);
create index procura_leituras_criado_idx on public.procura_leituras (criado_em desc);
create index procura_leituras_usuario_idx on public.procura_leituras (usuario_id);

-- O que a base diz sobre um código (contêiner, FcSku ou ASIN) no IOL atual
create or replace function private.procura_info(p_codigo text)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  with c as (select upper(btrim(p_codigo)) as c),
  m as (
    select a.container, a.sku, a.quantidade, a.local_atual, a.dias, s.nome as setor, inv.asin
      from public.iol_itens a
      join public.iol_setores s on s.id = a.setor_id
      left join public.inventario_sku inv on inv.fcsku = a.sku, c
     where a.resolvido_em is null and (upper(a.container) = c.c or upper(a.sku) = c.c or upper(inv.asin) = c.c)
  )
  select jsonb_build_object(
    'tipo', coalesce(
      (select case when bool_or(upper(m.container) = (select c from c)) then 'Contêiner'
                   when bool_or(upper(m.sku) = (select c from c)) then 'FcSku' else 'ASIN' end from m having count(*) > 0),
      case when (select c from c) ~ '^B0[A-Z0-9]{8}$' then 'ASIN'
           when (select c from c) ~ '^ZZ[A-Z0-9]{8}$' then 'FcSku'
           when (select c from c) ~ '^(TS|CB|PS|WS|DZ|PM|PA|RC)' then 'Contêiner'
           else 'Código' end),
    'itens',    (select count(*) from m),
    'unidades', (select coalesce(sum(quantidade), 0) from m),
    'asins',    (select count(distinct coalesce(asin, sku)) from m),
    'local',    (select min(local_atual) from m),
    'setores',  (select string_agg(distinct setor, ', ') from m),
    'dias_max', (select max(dias) from m));
$$;
revoke execute on function private.procura_info(text) from public, anon;
grant execute on function private.procura_info(text) to authenticated;

-- Lista ativa com o que a base diz sobre cada código
create or replace function public.procura_lista()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(r) order by (r.localizado_em is not null), r.id), '[]'::jsonb)
    from (
      select p.id, p.codigo, p.tipo, p.criado_em, p.autor_nome, p.criado_por, p.localizado_em, p.localizado_nome, p.localizado_no,
             i.info
        from public.procura_itens p
        left join lateral (
          select jsonb_build_object(
            'itens', count(*)::int,
            'unidades', coalesce(sum(a.quantidade), 0)::int,
            'asins', count(distinct coalesce(inv.asin, a.sku))::int,
            'local', min(a.local_atual),
            'setores', string_agg(distinct s.nome, ', '),
            'dias_max', max(a.dias)) as info
            from public.iol_itens a
            join public.iol_setores s on s.id = a.setor_id
            left join public.inventario_sku inv on inv.fcsku = a.sku
           where a.resolvido_em is null and (
                 (p.tipo = 'Contêiner' and upper(a.container) = p.codigo)
              or (p.tipo = 'FcSku' and upper(a.sku) = p.codigo)
              or (p.tipo = 'ASIN' and upper(inv.asin) = p.codigo))
        ) i on true
       where p.arquivado_em is null) r;
$$;

create or replace function public.procura_adicionar(p_codigos text[])
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_add int; v_total int;
begin
  if coalesce(array_length(p_codigos, 1), 0) > 3000 then
    raise exception 'Máximo de 3.000 códigos por vez';
  end if;
  select count(distinct upper(btrim(x)))::int into v_total from unnest(p_codigos) x where char_length(btrim(x)) between 3 and 80;
  insert into public.procura_itens (codigo, tipo, autor_nome)
  select t.c, private.procura_info(t.c)->>'tipo', (select p.nome from public.perfis p where p.id = (select auth.uid()))
    from (select distinct upper(btrim(x)) as c from unnest(p_codigos) x where char_length(btrim(x)) between 3 and 80) t
   where not exists (select 1 from public.procura_itens e where e.codigo = t.c and e.arquivado_em is null)
  on conflict do nothing;
  get diagnostics v_add = row_count;
  return jsonb_build_object('adicionados', v_add, 'ja_na_lista', v_total - v_add);
end;
$$;

-- Bipagem: grava a leitura e marca como localizado. Roda com privilégio elevado (operadores não editam a lista direto).
create or replace function private.procura_bipar_def(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c        text := upper(btrim(coalesce(p_codigo, '')));
  v_uid    uuid := (select auth.uid());
  v_nome   text;
  v_item   public.procura_itens;
  v_res    text;
  v_marc   text[];
  v_info   jsonb;
begin
  if v_uid is null or (select private.papel_atual()) not in ('operador', 'gestor', 'admin') then
    raise exception 'Você não tem permissão para esta ação.';
  end if;
  if char_length(c) < 3 or char_length(c) > 80 then
    raise exception 'Código inválido';
  end if;
  select nome into v_nome from public.perfis where id = v_uid;
  v_info := private.procura_info(c);

  select * into v_item from public.procura_itens where codigo = c and arquivado_em is null;
  if found then
    if v_item.localizado_em is null then
      update public.procura_itens set localizado_em = now(), localizado_por = v_uid, localizado_nome = v_nome, localizado_no = c where id = v_item.id;
      v_res := 'localizado';
    else
      v_res := 'ja_localizado';
    end if;
    v_marc := array[c];
  end if;

  -- bipou um contêiner que, pela base, guarda FcSku/ASIN ainda procurados na lista
  with up as (
    update public.procura_itens p
       set localizado_em = now(), localizado_por = v_uid, localizado_nome = v_nome, localizado_no = c
     where p.arquivado_em is null and p.localizado_em is null and p.tipo in ('FcSku', 'ASIN') and p.codigo <> c
       and exists (select 1 from public.iol_itens a left join public.inventario_sku inv on inv.fcsku = a.sku
                    where a.resolvido_em is null and upper(a.container) = c
                      and ((p.tipo = 'FcSku' and upper(a.sku) = p.codigo) or (p.tipo = 'ASIN' and upper(inv.asin) = p.codigo)))
    returning p.codigo)
  select coalesce(v_marc, '{}') || coalesce(array_agg(codigo order by codigo), '{}') into v_marc from up;
  if coalesce(array_length(v_marc, 1), 0) = 0 then
    v_marc := null; v_res := 'fora_da_lista';
  elsif v_res is null then
    v_res := 'localizado';
  end if;

  insert into public.procura_leituras (codigo, resultado, marcados, info, usuario_id, usuario_nome)
  values (c, v_res, array_to_string(v_marc, ', '), v_info, v_uid, v_nome);

  return jsonb_build_object('codigo', c, 'resultado', v_res, 'marcados', to_jsonb(coalesce(v_marc, '{}'::text[])), 'info', v_info);
end;
$$;
revoke all on function private.procura_bipar_def(text) from public, anon;
grant execute on function private.procura_bipar_def(text) to authenticated;

create or replace function public.procura_bipar(p_codigo text)
returns jsonb
language sql
security invoker
set search_path = ''
as $$ select private.procura_bipar_def(p_codigo); $$;

-- Tirar da lista (arquiva): operador só os próprios ainda não localizados; gestor/admin qualquer um
create or replace function public.procura_remover(p_id bigint default null)
returns int
language plpgsql
security invoker
set search_path = ''
as $$
declare v_n int;
begin
  update public.procura_itens set arquivado_em = now()
   where arquivado_em is null and (p_id is null or id = p_id);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

alter table public.procura_itens enable row level security;
alter table public.procura_leituras enable row level security;

create policy procura_sel on public.procura_itens for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy procura_ins on public.procura_itens for insert to authenticated
  with check ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));
create policy procura_upd on public.procura_itens for update to authenticated
  using ((select private.papel_atual()) in ('gestor', 'admin')
         or ((select private.papel_atual()) = 'operador' and criado_por = (select auth.uid()) and localizado_em is null and arquivado_em is null))
  with check ((select private.papel_atual()) in ('gestor', 'admin')
         or ((select private.papel_atual()) = 'operador' and criado_por = (select auth.uid()) and localizado_em is null));
create policy leituras_sel on public.procura_leituras for select to authenticated
  using ((select private.papel_atual()) in ('operador', 'gestor', 'admin'));

revoke all on public.procura_itens, public.procura_leituras from anon, authenticated;
grant select on public.procura_itens, public.procura_leituras to authenticated;
grant insert (codigo, tipo, autor_nome) on public.procura_itens to authenticated;
grant update (arquivado_em) on public.procura_itens to authenticated;

revoke execute on function public.procura_lista(), public.procura_adicionar(text[]), public.procura_bipar(text), public.procura_remover(bigint) from public, anon;
grant execute on function public.procura_lista(), public.procura_adicionar(text[]), public.procura_bipar(text), public.procura_remover(bigint) to authenticated;
