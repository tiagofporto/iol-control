-- Reações com emoji nas mensagens (alternam ao clicar de novo). Só quem participa da conversa lê ou reage.
create table public.mensagem_reacoes (
  mensagem_id bigint not null references public.mensagens (id) on delete cascade,
  usuario_id  uuid not null references public.perfis (id) on delete cascade,
  emoji       text not null check (emoji in ('👍', '✅', '👀', '🙏', '❤️', '😂')),
  criado_em   timestamptz not null default now(),
  primary key (mensagem_id, usuario_id, emoji)
);
create index mensagem_reacoes_usuario_idx on public.mensagem_reacoes (usuario_id);

alter table public.mensagem_reacoes enable row level security;
create policy reacoes_sel on public.mensagem_reacoes for select to authenticated
  using (mensagem_id in (select m.id from public.mensagens m));   -- herda a RLS das mensagens (só participantes)
revoke all on public.mensagem_reacoes from anon, authenticated;
grant select on public.mensagem_reacoes to authenticated;

create or replace function private.msg_reagir_def(p_mensagem bigint, p_emoji text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_eu uuid := (select auth.uid());
begin
  if v_eu is null or not private.msg_ativo() then raise exception 'Sem acesso às mensagens.' using errcode = '42501'; end if;
  if p_emoji is null or p_emoji not in ('👍', '✅', '👀', '🙏', '❤️', '😂') then raise exception 'Emoji não disponível.'; end if;
  if not exists (select 1 from public.mensagens m join public.conversa_membros cm on cm.conversa_id = m.conversa_id and cm.usuario_id = v_eu where m.id = p_mensagem) then
    raise exception 'Mensagem não encontrada.';
  end if;
  if exists (select 1 from public.mensagem_reacoes r where r.mensagem_id = p_mensagem and r.usuario_id = v_eu and r.emoji = p_emoji) then
    delete from public.mensagem_reacoes r where r.mensagem_id = p_mensagem and r.usuario_id = v_eu and r.emoji = p_emoji;
    return false;
  end if;
  insert into public.mensagem_reacoes (mensagem_id, usuario_id, emoji) values (p_mensagem, v_eu, p_emoji);
  return true;
end;
$$;
revoke all on function private.msg_reagir_def(bigint, text) from public, anon;
grant execute on function private.msg_reagir_def(bigint, text) to authenticated;

create or replace function public.msg_reagir(p_mensagem bigint, p_emoji text) returns boolean language sql security invoker set search_path = ''
as $$ select private.msg_reagir_def(p_mensagem, p_emoji); $$;

-- Reações de uma conversa, agrupadas por mensagem e emoji
create or replace function public.msg_reacoes(p_conversa bigint)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(to_jsonb(x) order by x.mensagem_id, x.primeira), '[]'::jsonb)
    from (
      select r.mensagem_id, r.emoji, count(*)::int as n, bool_or(r.usuario_id = (select auth.uid())) as eu,
             string_agg(coalesce(p.nome, 'Usuário'), ', ' order by r.criado_em) as nomes, min(r.criado_em) as primeira
        from public.mensagem_reacoes r
        join public.mensagens m on m.id = r.mensagem_id and m.conversa_id = p_conversa
        left join public.perfis p on p.id = r.usuario_id
       group by r.mensagem_id, r.emoji
    ) x;
$$;
revoke execute on function public.msg_reagir(bigint, text), public.msg_reacoes(bigint) from public, anon;
grant execute on function public.msg_reagir(bigint, text), public.msg_reacoes(bigint) to authenticated;
