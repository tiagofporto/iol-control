-- O login por "usuário" passa a ser resolvido na Edge Function login-usuario (service role).
-- Remove as funções que devolviam o e-mail a visitantes sem login.
drop function if exists public.login_para_email(text);
drop function if exists private.login_email(text);
