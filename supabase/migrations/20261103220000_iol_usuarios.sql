-- Usuários: perfil completo (setor, login, função, manager, foto), autoedição segura,
-- importação restrita a administradores e login por "login" ou e-mail.

alter table public.perfis
  add column login   text,
  add column setor   text,
  add column funcao  text,
  add column manager text,
  add column foto    text;

alter table public.perfis
  add constraint perfis_login_fmt check (login is null or login ~ '^[a-z0-9._-]{3,30}$'),
  add constraint perfis_foto_tam  check (foto is null or (char_length(foto) <= 150000 and foto like 'data:image/%')),
  add constraint perfis_txt_tam   check (char_length(coalesce(setor, '')) <= 80 and char_length(coalesce(funcao, '')) <= 80 and char_length(coalesce(manager, '')) <= 120 and char_length(nome) <= 120);
create unique index perfis_login_uk on public.perfis (login);

-- Quem tem acesso vê o perfil dos colegas (nome, foto, função: usados na presença e nos registros).
drop policy perfis_select on public.perfis;
create policy perfis_select on public.perfis for select to authenticated
  using (id = (select auth.uid()) or (select private.papel_atual()) in ('operador', 'gestor', 'admin'));

-- Cada um edita o próprio perfil; admin edita qualquer um. Papel e login só o admin altera (trigger abaixo).
create policy perfis_update_self on public.perfis for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()));
revoke update on public.perfis from authenticated;
grant update (nome, setor, funcao, manager, foto, login, papel) on public.perfis to authenticated;

create or replace function private.perfis_guarda()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  -- sem usuário logado (função de administração com service role, SQL do painel) não há o que restringir
  if (select auth.uid()) is not null and (select private.papel_atual()) is distinct from 'admin' then
    if new.papel is distinct from old.papel or new.login is distinct from old.login or new.email is distinct from old.email then
      raise exception 'Somente administradores alteram papel, login e e-mail.';
    end if;
  end if;
  if old.papel = 'admin' and new.papel <> 'admin'
     and not exists (select 1 from public.perfis p where p.papel = 'admin' and p.id <> old.id) then
    raise exception 'O sistema precisa de ao menos um administrador.';
  end if;
  new.nome := btrim(new.nome);
  new.login := nullif(lower(btrim(coalesce(new.login, ''))), '');
  new.setor := nullif(btrim(coalesce(new.setor, '')), '');
  new.funcao := nullif(btrim(coalesce(new.funcao, '')), '');
  new.manager := nullif(btrim(coalesce(new.manager, '')), '');
  if new.nome = '' then raise exception 'Informe o nome.'; end if;
  return new;
end;
$$;
create trigger perfis_guarda before update on public.perfis
  for each row execute function private.perfis_guarda();

-- Login: aceita o "login" no lugar do e-mail. Devolve só o e-mail daquele login (ou nulo).
create or replace function private.login_email(p_login text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.email from public.perfis p where p.login = lower(btrim(p_login)) limit 1;
$$;
revoke all on function private.login_email(text) from public;
grant execute on function private.login_email(text) to anon, authenticated;
grant usage on schema private to anon;

create or replace function public.login_para_email(p_login text)
returns text
language sql
stable
security invoker
set search_path = ''
as $$ select private.login_email(p_login); $$;
revoke execute on function public.login_para_email(text) from public;
grant execute on function public.login_para_email(text) to anon, authenticated;

-- Importação de bases: somente administradores (antes: gestor e admin).
alter policy importacoes_ins on public.iol_importacoes with check ((select private.papel_atual()) = 'admin');
alter policy importacoes_upd on public.iol_importacoes using ((select private.papel_atual()) = 'admin') with check ((select private.papel_atual()) = 'admin');
alter policy itens_ins on public.iol_itens with check ((select private.papel_atual()) = 'admin');
alter policy itens_upd on public.iol_itens using ((select private.papel_atual()) = 'admin') with check ((select private.papel_atual()) = 'admin');
alter policy mov_ins on public.iol_movimentos with check ((select private.papel_atual()) = 'admin');
alter policy base_imp_ins on public.base_importacoes with check ((select private.papel_atual()) = 'admin');
alter policy base_imp_upd on public.base_importacoes using ((select private.papel_atual()) = 'admin') with check ((select private.papel_atual()) = 'admin');
alter policy inv_ins on public.inventario_sku with check ((select private.papel_atual()) = 'admin');
alter policy inv_upd on public.inventario_sku using ((select private.papel_atual()) = 'admin') with check ((select private.papel_atual()) = 'admin');
alter policy rodeo_ins on public.rodeo_linhas with check ((select private.papel_atual()) = 'admin');
alter policy rodeo_del on public.rodeo_linhas using ((select private.papel_atual()) = 'admin');
alter policy vinculo_ins on public.iol_rodeo_vinculo with check ((select private.papel_atual()) = 'admin');
alter policy vinculo_del on public.iol_rodeo_vinculo using ((select private.papel_atual()) = 'admin');
