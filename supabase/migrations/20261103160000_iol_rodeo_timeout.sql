-- A finalização do Rodeo recalcula os vínculos (36 mil linhas × inventário) e estourava o limite de 8 s da API.
create index if not exists iol_itens_sku_idx on public.iol_itens (sku) where resolvido_em is null;
create index if not exists iol_itens_container_idx on public.iol_itens (container) where resolvido_em is null;
alter role authenticated set statement_timeout = '180s';
notify pgrst, 'reload config';
