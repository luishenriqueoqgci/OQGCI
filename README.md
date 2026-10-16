# Diagnóstico OQGCI

Aplicação web do Diagnóstico OQGCI (Metodologia OQGCI): página de entrada, referências científicas, cadastro e login, questionário com 33 afirmações, 6 situações e uma pergunta aberta, diagnóstico completo (Índice OQGCI, perfil, leitura das oito dimensões, postura, história de venda, sinais de resposta e prioridades) e painel do facilitador com turmas por código.

## Estrutura

| Pasta ou arquivo | Conteúdo |
| --- | --- |
| `src/app.html` | Código da aplicação (fonte única) |
| `build.py` | Gera `public/index.html` e a prévia a partir de `src/app.html` |
| `public/` | O site publicado pelo GitHub Pages |
| `public/config.js` | Endereço e chave pública do Supabase. Vazio = modo demonstração |
| `supabase/schema.sql` | Tabelas, regras de acesso e funções do banco |
| `.github/workflows/pages.yml` | Publicação automática no GitHub Pages a cada envio ao ramo `main` |
| `netlify/` e `netlify.toml` | Função de servidor da leitura da história por IA (opcional, hospedagem à parte) |

## Publicação gratuita, passo a passo

### 1. Supabase (login e banco de dados)
1. Crie uma conta em supabase.com e um novo projeto (região South America, São Paulo).
2. Abra **SQL Editor > New query**, cole o conteúdo de `supabase/schema.sql` e clique em **Run**.
3. Em **Project Settings > API**, copie o **Project URL** e a chave **anon public**.
4. Em **Authentication > URL Configuration**, preencha **Site URL** com o endereço do site no GitHub Pages (passo 2) e adicione o mesmo endereço em **Redirect URLs**.

### 2. GitHub Pages (site)
1. No repositório, abra **Settings > Pages** e escolha **GitHub Actions** como fonte.
2. O fluxo `.github/workflows/pages.yml` publica a pasta `public` a cada envio ao ramo `main`.
3. O endereço fica no formato `https://luishenriqueoqgci.github.io/OQGCI/`.

### 3. Ligar os dois
1. Preencha `public/config.js` com o Project URL e a chave anon public.
2. Ao salvar no GitHub, o GitHub Pages publica a nova versão sozinho.
3. Crie a sua conta no site e, no SQL Editor do Supabase, rode:
   `update public.profiles set role = 'facilitador' where email = 'seu-email';`
4. Entre de novo no site: o menu **Facilitador** aparece.

### 4. Domínio próprio (quando quiser)
Em **Settings > Pages > Custom domain**, informe o domínio e configure o DNS. Depois, atualize o Site URL no Supabase com o novo endereço.

### 5. Leitura da história por IA (opcional)
1. Crie uma chave no Console do Claude (console.anthropic.com). O uso da API é cobrado à parte da assinatura do Claude; os planos Max e Team incluem créditos mensais de API.
2. Publique a função da pasta `netlify/` num serviço que rode funções de servidor (o GitHub Pages só publica páginas) e crie nele as variáveis `ANTHROPIC_API_KEY`, `SUPABASE_URL` e `SUPABASE_ANON_KEY`.
3. Em `public/config.js`, troque `leituraIA: false` por `leituraIA: true`.
Sem isso, o relatório mostra a história com um roteiro de autoleitura.

### Atualizações do banco
Projetos criados com o `schema.sql` atual já têm tudo. Em projetos antigos, rode no **SQL Editor** (New query > colar > Run), uma vez cada, as atualizações que ainda não foram aplicadas:
- `supabase/atualizacao-01-tipo-de-negocio.sql` · pergunta do tipo de negócio por turma
- `supabase/atualizacao-02-controle-de-acesso.sql` · acesso por turma e por pessoa
- `supabase/atualizacao-03-evolucao.sql` · data de reavaliação da turma e relatório de evolução (pareamento automático, revisão e liberação pelo facilitador)
- `supabase/atualizacao-04-correcao-pareamento.sql` · correção do pareamento ao definir a data de reavaliação (necessária em quem já rodou a 03)
- `supabase/atualizacao-05-evolucao-individual.sql` · evolução individual opcional, habilitada pessoa a pessoa em Pessoas e acessos
- `supabase/atualizacao-06-etapas-e-pedidos.sql` · etapas da turma (prévia, workshop e 45 dias), turma patrocinada, limite de execuções por pessoa e pedidos de nova execução; retira a evolução individual por data da 05

## Observações
- A chave anon public pode ficar no site: o acesso aos dados é protegido pelas regras de RLS do `schema.sql`.
- No plano gratuito do Supabase, o projeto pode pausar após um período sem uso. Ele é reativado pelo painel.
- Para alterar a aplicação, edite `src/app.html` e rode `python3 build.py`.
- Relatório de evolução: na aba **Evolução** do painel do facilitador, defina a data de reavaliação da turma. O novo diagnóstico de cada pessoa a partir dessa data gera o relatório como rascunho; o facilitador revisa, comenta e libera, e a pessoa passa a ver o relatório e o PDF no próprio painel.
