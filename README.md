# IOL Control — gestão de itens sem armazenagem

Aplicação para acompanhar itens em IOL (parados no FC sem armazenagem): importação das bases por planilha, histórico de lançamentos e justificativas acompanhadas pelos gestores.

- **Front-end:** um único arquivo `dist/iol-manager.html` (sem dependências externas, fontes embutidas).
- **Banco:** Supabase (Postgres + Auth + RLS). Todo o schema está em `supabase/migrations/20261103000000_iol_schema.sql`.

## Como colocar no ar

### 1. Criar o banco
1. Crie um projeto no Supabase.
2. Abra **SQL Editor**, cole o conteúdo de `supabase/migrations/20261103000000_iol_schema.sql` e execute.
   (Com a CLI: copie o arquivo para `supabase/migrations/` do seu projeto e rode `supabase db push`.)
3. O script já inclui os `GRANT`s explícitos para a Data API, RLS em todas as tabelas, views com `security_invoker` e dados iniciais (12 setores, motivos e faixas de dias).

### 2. Conectar o app (use só a chave *publishable*)
Em **Project Settings → API** copie a *Project URL* e a *publishable key*. **Nunca** use a `secret`/`service_role` — o app a recusa.
Escolha uma das formas:

- **Tela de conexão do app:** abra o HTML e informe URL e chave (fica salvo no navegador).
- **Embutir no arquivo:** edite o bloco `<script type="application/json" id="iol-config">` do HTML, ou gere já configurado:
  `SUPABASE_URL=https://xxx.supabase.co SUPABASE_KEY=sb_publishable_... node build.mjs`

### 3. Usuários e perfis
- Em **Authentication → Providers**, deixe e-mail/senha ativo. Se quiser fechar o cadastro público, desative *Allow new users to sign up* e crie os usuários manualmente.
- **O primeiro cadastro vira Administrador.** Os demais entram como *Pendente* até um admin liberar em **Configurações → Usuários**.

| Papel | Pode |
|---|---|
| Pendente | nada (tela de espera) |
| Operador | ver itens, lançar justificativas |
| Gestor | tudo do operador + importar bases |
| Administrador | tudo + configurar faixas, motivos, setores e papéis |

### 4. Hospedagem
O HTML pode ser aberto direto, servido por qualquer hospedagem estática (Supabase Storage, Netlify, Vercel, intranet) ou publicado como Artifact.

## Uso

1. **Importar bases** (gestor/admin): arraste os CSV/XLSX. O setor é detectado pelo nome do arquivo (`Inbound-None(1).csv` → Inbound) e pode ser ajustado. A data de referência vem da data do arquivo.
2. **Itens em IOL:** filtre por dias (a partir de 0,5), setor, justificativa e busca; lance o motivo de um item, dos selecionados ou de **todos os filtrados**.
3. **Acompanhamento:** feed de justificativas para os gestores, com filtro por período, setor e motivo; o histórico completo de cada item abre pelo ícone de relógio.
4. **Painel:** totais por faixa, composição por setor, principais motivos, evolução e críticos sem justificativa.

### Faixas de dias (editáveis em Configurações)
| Faixa | Regra |
|---|---|
| Monitorar | ≥ 0,5 dia |
| Alerta | ≥ 3 dias |
| Crítico | ≥ 5 dias |

### Colunas reconhecidas nas planilhas
`FcSku`, `Tempo de inatividade (ms)`, `Quantidade`, `Disposição`, `Proprietário`, `Contêiner`, `Tipo de contêiner`, `Local externo`, `Tipo de local externo`, `Localização periférica`, `Tipo de localização mais distante` (também em inglês). Linhas repetidas do mesmo item são somadas.

## Regras de negócio

- **Identidade do item:** setor + SKU + contêiner + disposição + proprietário.
- **Importação = foto do setor:** itens que sumiram do novo arquivo são marcados como resolvidos; se voltarem, abrem um novo ciclo (sem justificativa), preservando o histórico.
- **Lançamentos são imutáveis** (só se acrescentam). A justificativa vigente do item é a última lançada.
- Dias em IOL são calculados na data de referência da importação.

## Premissas e limitações

- "5 dias acima" foi implementado como **≥ 5** (inclusive). Ajustável em Configurações.
- Se um item muda de contêiner, vira um item novo e perde a justificativa vigente (o histórico do antigo permanece).
- A lista de motivos inicial é uma sugestão; o admin edita.
- O código de acesso ao Supabase (`src/data/supabase.js`) ainda não foi exercitado contra um projeto real; o SQL foi testado em Postgres (PGlite) e o app inteiro em modo demonstração. Faça um teste de ponta a ponta no seu projeto antes de usar em produção.
- Leitura de `.xlsx` não foi testada com arquivo real (CSV foi).
- Importações interrompidas deixam registros `em_andamento`, ocultos no histórico.

## Desenvolvimento

```bash
npm install
npm run build                      # gera dist/iol-manager.html
node tests/db.test.mjs <pasta-csv> # testa schema, RLS e importação (PGlite)
node tests/e2e.cjs <pasta-csv>     # teste de ponta a ponta no navegador (modo demo)
```

O **modo demonstração** guarda os dados só no navegador (IndexedDB), útil para testar com suas planilhas antes de conectar o banco.


## Cruzamento IOL × Rodeo × Inventário

Em **Importar bases** envie, junto com as planilhas de IOL, a lista de envios do **Rodeo** e o **Inventário Geral** do FC (o tipo é detectado automaticamente).
- Produto: FcSku (IOL) → Inventário (FNSKU/ASIN) → FN SKU do Rodeo. Contêiner: Container (IOL) = Scannable ID (Rodeo).
- Tudo em **Crossdock** no Rodeo é tratado como setor **IXD**.
- O Rodeo é sempre a foto mais recente; o Inventário é acumulativo. Tela: **IOL × Rodeo**.

## Procurar (PROCV de itens perdidos)
Aba "Procurar": cole contêineres, FcSkus ou ASINs, bipe com o coletor; localizado fica verde, com sinal sonoro para localizado e não localizado. Toda leitura é gravada em `procura_leituras` (imutável) para auditoria, com filtro por usuário e exportação CSV.

## Justificar por planilha
Aba "Justificar por planilha": baixe o modelo Excel (em branco ou já com os itens em IOL), preencha Motivo/Observação/Previsão/Setor que deve tratar e envie. O sistema valida linha a linha e mostra uma prévia antes de gravar. Uma cópia do modelo em branco está em `IOL_modelo_justificativas.xlsx`.
