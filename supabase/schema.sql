-- Diagnóstico OQGCI · estrutura do banco no Supabase
-- Como usar: no painel do Supabase, abra SQL Editor > New query, cole este arquivo inteiro e clique em Run.

-- 1. Perfis de usuário ---------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  nome text,
  email text,
  role text not null default 'respondente' check (role in ('respondente', 'facilitador')),
  consentimento_em timestamptz,
  created_at timestamptz not null default now()
);

-- Cria o perfil automaticamente a cada novo cadastro
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, nome, email, consentimento_em)
  values (new.id, new.raw_user_meta_data ->> 'nome', new.email, now())
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.is_facilitador()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles where id = auth.uid() and role = 'facilitador');
$$;

-- 2. Turmas ---------------------------------------------------------------------
create table if not exists public.turmas (
  id uuid primary key default gen_random_uuid(),
  nome text not null,
  codigo text not null unique,
  perguntar_nicho boolean not null default true,
  facilitador_id uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

-- Busca de turma pelo código, sem expor a lista de turmas aos respondentes
drop function if exists public.turma_por_codigo(text);
create function public.turma_por_codigo(p_codigo text)
returns table (id uuid, nome text, perguntar_nicho boolean) language sql stable security definer set search_path = public as $$
  select t.id, t.nome, t.perguntar_nicho from public.turmas t where upper(t.codigo) = upper(trim(p_codigo)) limit 1;
$$;

-- 3. Resultados -----------------------------------------------------------------
create table if not exists public.resultados (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  turma_id uuid references public.turmas (id) on delete set null,
  respostas jsonb not null,
  resultado jsonb not null,
  indice numeric,
  nivel text,
  perfil text,
  created_at timestamptz not null default now()
);
create index if not exists resultados_turma_idx on public.resultados (turma_id);
create index if not exists resultados_user_idx on public.resultados (user_id);

-- 4. Regras de acesso (RLS) -----------------------------------------------------
alter table public.profiles enable row level security;
alter table public.turmas enable row level security;
alter table public.resultados enable row level security;

drop policy if exists "perfil: ler o próprio ou facilitador" on public.profiles;
create policy "perfil: ler o próprio ou facilitador" on public.profiles
  for select using (id = auth.uid() or public.is_facilitador());

drop policy if exists "perfil: atualizar o próprio" on public.profiles;
create policy "perfil: atualizar o próprio" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- O usuário só pode alterar o próprio nome; o papel (role) muda apenas pelo painel do Supabase
revoke update on public.profiles from authenticated, anon;
grant update (nome) on public.profiles to authenticated;

drop policy if exists "turmas: facilitador lê" on public.turmas;
create policy "turmas: facilitador lê" on public.turmas
  for select using (public.is_facilitador());

drop policy if exists "turmas: facilitador cria" on public.turmas;
create policy "turmas: facilitador cria" on public.turmas
  for insert with check (public.is_facilitador());

drop policy if exists "turmas: facilitador altera" on public.turmas;
create policy "turmas: facilitador altera" on public.turmas
  for update using (public.is_facilitador());

drop policy if exists "turmas: facilitador exclui" on public.turmas;
create policy "turmas: facilitador exclui" on public.turmas
  for delete using (public.is_facilitador());

drop policy if exists "resultados: ler os próprios ou facilitador" on public.resultados;
create policy "resultados: ler os próprios ou facilitador" on public.resultados
  for select using (user_id = auth.uid() or public.is_facilitador());

drop policy if exists "resultados: gravar os próprios" on public.resultados;
create policy "resultados: gravar os próprios" on public.resultados
  for insert with check (user_id = auth.uid());

drop policy if exists "resultados: excluir os próprios" on public.resultados;
create policy "resultados: excluir os próprios" on public.resultados
  for delete using (user_id = auth.uid());

grant execute on function public.turma_por_codigo(text) to authenticated;
grant execute on function public.is_facilitador() to authenticated;

-- 5. Tornar a sua conta facilitadora --------------------------------------------
-- Depois de criar a sua conta no site, rode a linha abaixo trocando o e-mail:
-- update public.profiles set role = 'facilitador' where email = 'seu-email@exemplo.com';

-- 6. Controle de acesso (mesmo conteúdo de atualizacao-02-controle-de-acesso.sql) ---------
-- 1. Novas colunas ---------------------------------------------------------------
alter table public.turmas add column if not exists expira_em date;
alter table public.profiles add column if not exists turma_id uuid references public.turmas (id) on delete set null;
alter table public.profiles add column if not exists acesso_ate date;
alter table public.profiles add column if not exists acesso_bloqueado boolean not null default false;

-- Quem já respondeu com uma turma fica vinculado à última turma usada
update public.profiles p set turma_id = (
  select r.turma_id from public.resultados r
  where r.user_id = p.id and r.turma_id is not null
  order by r.created_at desc limit 1)
where p.turma_id is null;

-- 2. Situação de acesso de uma pessoa ----------------------------------------------
create or replace function public.hoje_br()
returns date language sql stable as $$ select (now() at time zone 'America/Sao_Paulo')::date $$;

drop function if exists public.acesso_de(uuid);
create function public.acesso_de(p_user uuid)
returns table (pode boolean, motivo text, valido_ate date, turma_id uuid, turma_nome text, perguntar_nicho boolean, turma_expira date, acesso_ate date, acesso_bloqueado boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  p public.profiles%rowtype;
  t public.turmas%rowtype;
  hoje date := public.hoje_br();
  ind boolean;
  tur boolean;
begin
  select * into p from public.profiles where id = p_user;
  if not found then
    return query select false, 'sem_acesso'::text, null::date, null::uuid, null::text, true, null::date, null::date, false;
    return;
  end if;
  if p.turma_id is not null then select * into t from public.turmas where id = p.turma_id; end if;
  ind := p.acesso_ate is not null and p.acesso_ate >= hoje;
  tur := t.id is not null and (t.expira_em is null or t.expira_em >= hoje);
  return query select
    (p.role = 'facilitador') or (not p.acesso_bloqueado and (ind or tur)),
    case when p.role = 'facilitador' then 'facilitador'
         when p.acesso_bloqueado then 'encerrado'
         when ind or tur then 'ativo'
         when t.id is not null or p.acesso_ate is not null then 'expirado'
         else 'sem_acesso' end,
    case when tur and t.expira_em is null then null
         else greatest(case when ind then p.acesso_ate end, case when tur then t.expira_em end,
                       case when not ind and not tur then greatest(p.acesso_ate, t.expira_em) end) end,
    t.id, t.nome, coalesce(t.perguntar_nicho, true), t.expira_em, p.acesso_ate, p.acesso_bloqueado;
end;
$$;

-- Situação da própria pessoa
drop function if exists public.meu_acesso();
create function public.meu_acesso()
returns table (pode boolean, motivo text, valido_ate date, turma_id uuid, turma_nome text, perguntar_nicho boolean, turma_expira date, acesso_ate date, acesso_bloqueado boolean)
language sql stable security definer set search_path = public as $$
  select * from public.acesso_de(auth.uid());
$$;

create or replace function public.pode_diagnosticar(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select pode from public.acesso_de(p_user)), false);
$$;

-- 3. Entrar numa turma pelo código --------------------------------------------------
drop function if exists public.entrar_turma(text);
create function public.entrar_turma(p_codigo text)
returns table (status text, id uuid, nome text, perguntar_nicho boolean, expira_em date)
language plpgsql security definer set search_path = public as $$
declare t public.turmas%rowtype;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  select * into t from public.turmas where upper(codigo) = upper(trim(p_codigo)) limit 1;
  if not found then
    return query select 'nao_encontrada'::text, null::uuid, null::text, null::boolean, null::date; return;
  end if;
  if t.expira_em is not null and t.expira_em < public.hoje_br() then
    return query select 'expirada'::text, t.id, t.nome, t.perguntar_nicho, t.expira_em; return;
  end if;
  update public.profiles set turma_id = t.id where public.profiles.id = auth.uid();
  return query select 'ok'::text, t.id, t.nome, t.perguntar_nicho, t.expira_em;
end;
$$;

-- 4. Gestão de pessoas pelo facilitador -----------------------------------------------
drop function if exists public.pessoas();
create function public.pessoas()
returns table (id uuid, nome text, email text, role text, created_at timestamptz, turma_id uuid, turma_nome text, turma_expira date,
               acesso_ate date, acesso_bloqueado boolean, pode boolean, motivo text, valido_ate date, diagnosticos bigint, ultimo timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  return query
    select p.id, p.nome, p.email, p.role, p.created_at, a.turma_id, a.turma_nome, a.turma_expira,
           a.acesso_ate, a.acesso_bloqueado, a.pode, a.motivo, a.valido_ate,
           (select count(*) from public.resultados r where r.user_id = p.id),
           (select max(r.created_at) from public.resultados r where r.user_id = p.id)
    from public.profiles p cross join lateral public.acesso_de(p.id) a
    order by p.created_at desc;
end;
$$;

drop function if exists public.definir_acesso(uuid, date, boolean);
create function public.definir_acesso(p_user uuid, p_ate date, p_bloqueado boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  update public.profiles set acesso_ate = p_ate, acesso_bloqueado = coalesce(p_bloqueado, false) where id = p_user;
end;
$$;

-- 5. Regra na gravação: só grava diagnóstico novo quem tem acesso ativo -----------------
drop policy if exists "resultados: gravar os próprios" on public.resultados;
create policy "resultados: gravar os próprios" on public.resultados
  for insert with check (user_id = auth.uid() and public.pode_diagnosticar(auth.uid()));

-- O usuário continua podendo alterar apenas o próprio nome; turma, validade e bloqueio mudam só pelas funções acima
revoke update on public.profiles from authenticated, anon;
grant update (nome) on public.profiles to authenticated;

revoke execute on function public.acesso_de(uuid) from public, anon, authenticated;
grant execute on function public.meu_acesso() to authenticated;
grant execute on function public.pode_diagnosticar(uuid) to authenticated;
grant execute on function public.entrar_turma(text) to authenticated;
grant execute on function public.pessoas() to authenticated;
grant execute on function public.definir_acesso(uuid, date, boolean) to authenticated;

-- 7. Relatório de evolução (mesmo conteúdo de atualizacao-03-evolucao.sql) ---------------
-- 1. Data de reavaliação da turma ---------------------------------------------------
alter table public.turmas add column if not exists reavaliar_em date;

-- 2. Relatórios de evolução ------------------------------------------------------------
create table if not exists public.evolucoes (
  id uuid primary key default gen_random_uuid(),
  turma_id uuid not null references public.turmas (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  inicial_id uuid not null references public.resultados (id) on delete cascade,
  reavaliacao_id uuid not null references public.resultados (id) on delete cascade,
  comentario text,
  status text not null default 'rascunho' check (status in ('rascunho', 'liberado')),
  gerado_em timestamptz not null default now(),
  liberado_em timestamptz,
  unique (turma_id, user_id)
);
create index if not exists evolucoes_user_idx on public.evolucoes (user_id);

alter table public.evolucoes enable row level security;

drop policy if exists "evolucoes: facilitador gerencia" on public.evolucoes;
create policy "evolucoes: facilitador gerencia" on public.evolucoes
  for all using (public.is_facilitador()) with check (public.is_facilitador());

drop policy if exists "evolucoes: participante lê a própria liberada" on public.evolucoes;
create policy "evolucoes: participante lê a própria liberada" on public.evolucoes
  for select using (user_id = auth.uid() and status = 'liberado');

grant select, insert, update, delete on public.evolucoes to authenticated;

-- 3. Pareamento automático a cada diagnóstico gravado -----------------------------------
create or replace function public.parear_evolucao()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t public.turmas%rowtype;
  ini uuid;
begin
  if new.turma_id is null then return new; end if;
  select * into t from public.turmas where id = new.turma_id;
  if t.reavaliar_em is null
     or (new.created_at at time zone 'America/Sao_Paulo')::date < t.reavaliar_em then
    return new;
  end if;
  select r.id into ini from public.resultados r
   where r.user_id = new.user_id and r.turma_id = new.turma_id
     and (r.created_at at time zone 'America/Sao_Paulo')::date < t.reavaliar_em
   order by r.created_at desc limit 1;
  if ini is null then return new; end if;
  insert into public.evolucoes (turma_id, user_id, inicial_id, reavaliacao_id)
  values (new.turma_id, new.user_id, ini, new.id)
  on conflict (turma_id, user_id) do update
    set inicial_id = excluded.inicial_id, reavaliacao_id = excluded.reavaliacao_id,
        status = 'rascunho', liberado_em = null, gerado_em = now();
  return new;
end;
$$;

drop trigger if exists resultados_parear_evolucao on public.resultados;
create trigger resultados_parear_evolucao
  after insert on public.resultados
  for each row execute function public.parear_evolucao();

-- 4. Refazer os pares de uma turma (usado quando a data de reavaliação muda) -------------
-- Relatórios já liberados com o mesmo par continuam liberados; rascunhos que deixaram de valer são removidos.
drop function if exists public.pares_turma(uuid);
create function public.pares_turma(p_turma uuid)
returns table (user_id uuid, inicial_id uuid, reavaliacao_id uuid)
language sql stable security definer set search_path = public as $$
  with t as (select reavaliar_em from public.turmas where id = p_turma),
  rv as (
    select distinct on (r.user_id) r.user_id, r.id
    from public.resultados r, t
    where r.turma_id = p_turma and t.reavaliar_em is not null
      and (r.created_at at time zone 'America/Sao_Paulo')::date >= t.reavaliar_em
    order by r.user_id, r.created_at desc
  )
  select * from (
    select rv.user_id,
           (select r.id from public.resultados r, t
             where r.user_id = rv.user_id and r.turma_id = p_turma
               and (r.created_at at time zone 'America/Sao_Paulo')::date < t.reavaliar_em
             order by r.created_at desc limit 1) as inicial_id,
           rv.id as reavaliacao_id
    from rv
  ) x where x.inicial_id is not null;
$$;

drop function if exists public.parear_turma(uuid);
create function public.parear_turma(p_turma uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer := 0;
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  if not exists (select 1 from public.turmas where id = p_turma) then return 0; end if;

  delete from public.evolucoes e
   where e.turma_id = p_turma and e.status = 'rascunho'
     and not exists (select 1 from public.pares_turma(p_turma) p where p.user_id = e.user_id);

  insert into public.evolucoes (turma_id, user_id, inicial_id, reavaliacao_id)
  select p_turma, p.user_id, p.inicial_id, p.reavaliacao_id from public.pares_turma(p_turma) p
  on conflict (turma_id, user_id) do update
    set inicial_id = excluded.inicial_id,
        reavaliacao_id = excluded.reavaliacao_id,
        status = case when public.evolucoes.reavaliacao_id = excluded.reavaliacao_id
                       and public.evolucoes.inicial_id = excluded.inicial_id
                      then public.evolucoes.status else 'rascunho' end,
        liberado_em = case when public.evolucoes.reavaliacao_id = excluded.reavaliacao_id
                            and public.evolucoes.inicial_id = excluded.inicial_id
                           then public.evolucoes.liberado_em else null end,
        gerado_em = case when public.evolucoes.reavaliacao_id = excluded.reavaliacao_id
                          and public.evolucoes.inicial_id = excluded.inicial_id
                         then public.evolucoes.gerado_em else now() end;

  select count(*) into n from public.pares_turma(p_turma);
  return n;
end;
$$;

-- 5. Situação da reavaliação para a própria pessoa ------------------------------------
-- Mostra a data de reavaliação da turma e se o relatório está em revisão ou liberado.
drop function if exists public.minha_reavaliacao();
create function public.minha_reavaliacao()
returns table (turma_id uuid, turma_nome text, reavaliar_em date, status text)
language sql stable security definer set search_path = public as $$
  select t.id, t.nome, t.reavaliar_em,
         (select e.status from public.evolucoes e where e.user_id = auth.uid() and e.turma_id = t.id)
  from public.profiles p join public.turmas t on t.id = p.turma_id
  where p.id = auth.uid();
$$;

grant execute on function public.parear_turma(uuid) to authenticated;
grant execute on function public.minha_reavaliacao() to authenticated;
revoke execute on function public.parear_evolucao() from public, anon, authenticated;
revoke execute on function public.pares_turma(uuid) from public, anon, authenticated;

-- 8. Etapas da turma, turma patrocinada e pedidos de nova execução (mesmo conteúdo de atualizacao-06-etapas-e-pedidos.sql) ---
-- 1. Turmas ---------------------------------------------------------------------------
alter table public.turmas add column if not exists patrocinada boolean not null default false;
alter table public.turmas add column if not exists data_workshop date;

-- 2. Execuções por pessoa ------------------------------------------------------------------
alter table public.profiles add column if not exists nova_execucao boolean not null default false;
alter table public.profiles add column if not exists limite_execucoes integer not null default 1;
alter table public.profiles drop constraint if exists profiles_limite_execucoes_check;
alter table public.profiles add constraint profiles_limite_execucoes_check check (limite_execucoes between 1 and 50);

-- 3. Etapa da turma em uma data ----------------------------------------------------------
create or replace function public.etapa_turma(p_turma uuid, p_dia date)
returns text language sql stable security definer set search_path = public as $$
  select case
    when t.id is null then null
    when t.reavaliar_em is not null and p_dia >= t.reavaliar_em then 'reavaliacao'
    when t.data_workshop is null then 'inicial'
    when p_dia < t.data_workshop then 'previa'
    when p_dia = t.data_workshop then 'workshop'
    else 'intervalo' end
  from (select 1) x left join public.turmas t on t.id = p_turma;
$$;

-- A etapa de hoje está aberta e a pessoa ainda não executou nela?
create or replace function public.etapa_livre(p_user uuid, p_turma uuid)
returns boolean language sql stable security definer set search_path = public as $$
  with e as (select public.etapa_turma(p_turma, public.hoje_br()) as atual)
  select coalesce(e.atual is not null and e.atual <> 'intervalo'
     and not exists (select 1 from public.resultados r
                      where r.user_id = p_user and r.turma_id = p_turma
                        and public.etapa_turma(p_turma, (r.created_at at time zone 'America/Sao_Paulo')::date) = e.atual), false)
  from e;
$$;

-- 4. Situação de acesso: agora considera etapas e limite de execuções --------------------
-- Novo motivo 'limite': a pessoa tem acesso válido, mas não tem execução disponível agora.
create or replace function public.acesso_de(p_user uuid)
returns table (pode boolean, motivo text, valido_ate date, turma_id uuid, turma_nome text, perguntar_nicho boolean, turma_expira date, acesso_ate date, acesso_bloqueado boolean)
language plpgsql stable security definer set search_path = public as $$
declare
  p public.profiles%rowtype;
  t public.turmas%rowtype;
  hoje date := public.hoje_br();
  ind boolean;
  tur boolean;
  n integer;
  lim integer;
  via_ind boolean;
  via_tur boolean;
begin
  select * into p from public.profiles where id = p_user;
  if not found then
    return query select false, 'sem_acesso'::text, null::date, null::uuid, null::text, true, null::date, null::date, false;
    return;
  end if;
  if p.turma_id is not null then select * into t from public.turmas where id = p.turma_id; end if;
  ind := p.acesso_ate is not null and p.acesso_ate >= hoje;
  tur := t.id is not null and (t.expira_em is null or t.expira_em >= hoje);
  select count(*) into n from public.resultados r where r.user_id = p_user;
  lim := case when p.nova_execucao then greatest(p.limite_execucoes, 1) else 1 end;
  via_ind := ind and n < lim;
  via_tur := tur and public.etapa_livre(p_user, t.id);
  return query select
    (p.role = 'facilitador') or (not p.acesso_bloqueado and (via_ind or via_tur)),
    case when p.role = 'facilitador' then 'facilitador'
         when p.acesso_bloqueado then 'encerrado'
         when via_ind or via_tur then 'ativo'
         when ind or tur then 'limite'
         when t.id is not null or p.acesso_ate is not null then 'expirado'
         else 'sem_acesso' end,
    case when tur and t.expira_em is null then null
         else greatest(case when ind then p.acesso_ate end, case when tur then t.expira_em end,
                       case when not ind and not tur then greatest(p.acesso_ate, t.expira_em) end) end,
    t.id, t.nome, coalesce(t.perguntar_nicho, true), t.expira_em, p.acesso_ate, p.acesso_bloqueado;
end;
$$;

-- 5. Ao atingir o limite, a permissão de nova execução é desligada ------------------------
create or replace function public.consumir_execucao()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profiles p set nova_execucao = false
   where p.id = new.user_id and p.nova_execucao
     and (select count(*) from public.resultados r where r.user_id = new.user_id) >= p.limite_execucoes;
  return new;
end;
$$;
drop trigger if exists resultados_consumir_execucao on public.resultados;
create trigger resultados_consumir_execucao
  after insert on public.resultados
  for each row execute function public.consumir_execucao();

-- 6. Pedidos de nova execução -----------------------------------------------------------
create table if not exists public.pedidos_execucao (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  motivo text not null check (char_length(trim(motivo)) between 3 and 1000),
  status text not null default 'pendente' check (status in ('pendente', 'aprovado', 'recusado')),
  resposta text,
  created_at timestamptz not null default now(),
  decidido_em timestamptz
);
create unique index if not exists pedidos_execucao_pendente_uq on public.pedidos_execucao (user_id) where status = 'pendente';
create index if not exists pedidos_execucao_user_idx on public.pedidos_execucao (user_id, created_at desc);

alter table public.pedidos_execucao enable row level security;
drop policy if exists "pedidos: ler os próprios ou facilitador" on public.pedidos_execucao;
create policy "pedidos: ler os próprios ou facilitador" on public.pedidos_execucao
  for select using (user_id = auth.uid() or public.is_facilitador());
drop policy if exists "pedidos: a pessoa abre o próprio" on public.pedidos_execucao;
create policy "pedidos: a pessoa abre o próprio" on public.pedidos_execucao
  for insert with check (user_id = auth.uid() and status = 'pendente' and resposta is null and decidido_em is null);
drop policy if exists "pedidos: facilitador decide" on public.pedidos_execucao;
create policy "pedidos: facilitador decide" on public.pedidos_execucao
  for update using (public.is_facilitador()) with check (public.is_facilitador());
drop policy if exists "pedidos: facilitador remove" on public.pedidos_execucao;
create policy "pedidos: facilitador remove" on public.pedidos_execucao
  for delete using (public.is_facilitador());
grant select, insert, update, delete on public.pedidos_execucao to authenticated;

-- Decidir um pedido: liberar (com novo limite total e data) ou recusar, sempre com resposta opcional para a pessoa.
drop function if exists public.decidir_pedido(uuid, boolean, text, integer, date);
create function public.decidir_pedido(p_pedido uuid, p_aprovar boolean, p_resposta text, p_limite integer, p_ate date)
returns void language plpgsql security definer set search_path = public as $$
declare
  u uuid;
  n integer;
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  select pe.user_id into u from public.pedidos_execucao pe where pe.id = p_pedido and pe.status = 'pendente';
  if u is null then raise exception 'pedido_inexistente'; end if;
  if p_aprovar then
    select count(*) into n from public.resultados r where r.user_id = u;
    if p_limite is null or p_limite <= n then raise exception 'limite_baixo'; end if;
    if p_ate is null or p_ate < public.hoje_br() then raise exception 'data_invalida'; end if;
    update public.profiles set nova_execucao = true, limite_execucoes = p_limite, acesso_ate = p_ate, acesso_bloqueado = false where id = u;
  end if;
  update public.pedidos_execucao
     set status = case when p_aprovar then 'aprovado' else 'recusado' end,
         resposta = nullif(trim(coalesce(p_resposta, '')), ''),
         decidido_em = now()
   where id = p_pedido;
end;
$$;

-- Permitir ou não nova execução direto em Pessoas e acessos, sem pedido.
drop function if exists public.definir_execucoes(uuid, boolean, integer);
create function public.definir_execucoes(p_user uuid, p_nova boolean, p_limite integer)
returns void language plpgsql security definer set search_path = public as $$
declare n integer;
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  if p_nova then
    select count(*) into n from public.resultados r where r.user_id = p_user;
    if p_limite is null or p_limite <= n then raise exception 'limite_baixo'; end if;
    update public.profiles set nova_execucao = true, limite_execucoes = p_limite where id = p_user;
  else
    update public.profiles set nova_execucao = false where id = p_user;
  end if;
end;
$$;

-- 7. Lista de pessoas com execuções e último pedido --------------------------------------
drop function if exists public.pessoas();
create function public.pessoas()
returns table (id uuid, nome text, email text, role text, created_at timestamptz, turma_id uuid, turma_nome text, turma_expira date,
               acesso_ate date, acesso_bloqueado boolean, pode boolean, motivo text, valido_ate date, diagnosticos bigint, ultimo timestamptz,
               nova_execucao boolean, limite_execucoes integer,
               pedido_id uuid, pedido_status text, pedido_motivo text, pedido_em timestamptz)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  return query
    select p.id, p.nome, p.email, p.role, p.created_at, a.turma_id, a.turma_nome, a.turma_expira,
           a.acesso_ate, a.acesso_bloqueado, a.pode, a.motivo, a.valido_ate,
           (select count(*) from public.resultados r where r.user_id = p.id),
           (select max(r.created_at) from public.resultados r where r.user_id = p.id),
           p.nova_execucao, p.limite_execucoes,
           pd.id, pd.status, pd.motivo, pd.created_at
    from public.profiles p
    cross join lateral public.acesso_de(p.id) a
    left join lateral (select pe.id, pe.status, pe.motivo, pe.created_at from public.pedidos_execucao pe
                        where pe.user_id = p.id order by pe.created_at desc limit 1) pd on true
    order by p.created_at desc;
end;
$$;

-- 8. Retirada da evolução individual por data (atualização 05) ----------------------------
create or replace function public.parear_evolucao()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t public.turmas%rowtype;
  ini uuid;
begin
  if new.turma_id is null then return new; end if;
  select * into t from public.turmas where id = new.turma_id;
  if t.reavaliar_em is null
     or (new.created_at at time zone 'America/Sao_Paulo')::date < t.reavaliar_em then
    return new;
  end if;
  select r.id into ini from public.resultados r
   where r.user_id = new.user_id and r.turma_id = new.turma_id
     and (r.created_at at time zone 'America/Sao_Paulo')::date < t.reavaliar_em
   order by r.created_at desc limit 1;
  if ini is null then return new; end if;
  insert into public.evolucoes (turma_id, user_id, inicial_id, reavaliacao_id)
  values (new.turma_id, new.user_id, ini, new.id)
  on conflict (turma_id, user_id) do update
    set inicial_id = excluded.inicial_id, reavaliacao_id = excluded.reavaliacao_id,
        status = 'rascunho', liberado_em = null, gerado_em = now();
  return new;
end;
$$;

drop function if exists public.minha_reavaliacao();
create function public.minha_reavaliacao()
returns table (turma_id uuid, turma_nome text, reavaliar_em date, status text)
language sql stable security definer set search_path = public as $$
  select t.id, t.nome, t.reavaliar_em,
         (select e.status from public.evolucoes e where e.user_id = auth.uid() and e.turma_id = t.id)
  from public.profiles p join public.turmas t on t.id = p.turma_id
  where p.id = auth.uid();
$$;

drop function if exists public.definir_reavaliacao_individual(uuid, date);
drop function if exists public.par_individual(uuid);
delete from public.evolucoes where turma_id is null and status = 'rascunho';
alter table public.profiles drop column if exists reavaliar_em;

revoke execute on function public.parear_evolucao() from public, anon, authenticated;
revoke execute on function public.consumir_execucao() from public, anon, authenticated;
revoke execute on function public.acesso_de(uuid) from public, anon, authenticated;
revoke execute on function public.etapa_livre(uuid, uuid) from public, anon, authenticated;
grant execute on function public.etapa_turma(uuid, date) to authenticated;
grant execute on function public.decidir_pedido(uuid, boolean, text, integer, date) to authenticated;
grant execute on function public.definir_execucoes(uuid, boolean, integer) to authenticated;
grant execute on function public.pessoas() to authenticated;
grant execute on function public.minha_reavaliacao() to authenticated;

-- 9. Relatório de evolução por etapas e evolução individual (mesmo conteúdo de atualizacao-07-evolucao-por-etapas.sql) ---
-- 1. Novas colunas e chaves ---------------------------------------------------------------
alter table public.evolucoes add column if not exists tipo text not null default 'completo';
alter table public.evolucoes drop constraint if exists evolucoes_tipo_check;
alter table public.evolucoes add constraint evolucoes_tipo_check check (tipo in ('workshop', 'completo', 'individual'));
alter table public.evolucoes add column if not exists intermediario_id uuid references public.resultados (id) on delete set null;
alter table public.evolucoes alter column turma_id drop not null;
alter table public.evolucoes drop constraint if exists evolucoes_turma_id_user_id_key;
drop index if exists public.evolucoes_individual_uq;
update public.evolucoes set tipo = 'individual' where turma_id is null and tipo <> 'individual';
create unique index if not exists evolucoes_turma_tipo_uq on public.evolucoes (turma_id, user_id, tipo) where turma_id is not null;
create unique index if not exists evolucoes_individual_rea_uq on public.evolucoes (reavaliacao_id) where tipo = 'individual';

-- A pessoa nunca vê o relatório interno prévia -> workshop.
drop policy if exists "evolucoes: participante lê a própria liberada" on public.evolucoes;
create policy "evolucoes: participante lê a própria liberada" on public.evolucoes
  for select using (user_id = auth.uid() and status = 'liberado' and tipo <> 'workshop');

-- 2. Grava um relatório: par igual mantém a revisão feita; par novo volta para rascunho -------
create or replace function public.gravar_evolucao(p_turma uuid, p_user uuid, p_tipo text, p_ini uuid, p_meio uuid, p_rea uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e public.evolucoes%rowtype;
begin
  if p_tipo = 'individual' then
    select * into e from public.evolucoes where tipo = 'individual' and reavaliacao_id = p_rea;
  else
    select * into e from public.evolucoes where turma_id = p_turma and user_id = p_user and tipo = p_tipo;
  end if;
  if e.id is null then
    insert into public.evolucoes (turma_id, user_id, tipo, inicial_id, intermediario_id, reavaliacao_id)
    values (p_turma, p_user, p_tipo, p_ini, p_meio, p_rea);
  elsif e.inicial_id is distinct from p_ini or e.intermediario_id is distinct from p_meio or e.reavaliacao_id is distinct from p_rea then
    update public.evolucoes
       set inicial_id = p_ini, intermediario_id = p_meio, reavaliacao_id = p_rea,
           status = 'rascunho', liberado_em = null, gerado_em = now()
     where id = e.id;
  end if;
end;
$$;

-- 3. Relatórios de turma de uma pessoa, a partir das etapas -----------------------------------
create or replace function public.parear_pessoa_turma(p_user uuid, p_turma uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  pv uuid; wk uuid; rv uuid;
begin
  select r.id into pv from public.resultados r
   where r.user_id = p_user and r.turma_id = p_turma
     and public.etapa_turma(p_turma, (r.created_at at time zone 'America/Sao_Paulo')::date) in ('previa', 'inicial')
   order by r.created_at desc limit 1;
  select r.id into wk from public.resultados r
   where r.user_id = p_user and r.turma_id = p_turma
     and public.etapa_turma(p_turma, (r.created_at at time zone 'America/Sao_Paulo')::date) = 'workshop'
   order by r.created_at asc limit 1;
  select r.id into rv from public.resultados r
   where r.user_id = p_user and r.turma_id = p_turma
     and public.etapa_turma(p_turma, (r.created_at at time zone 'America/Sao_Paulo')::date) = 'reavaliacao'
   order by r.created_at asc limit 1;

  if pv is not null and wk is not null then
    perform public.gravar_evolucao(p_turma, p_user, 'workshop', pv, null, wk);
  else
    delete from public.evolucoes e where e.turma_id = p_turma and e.user_id = p_user and e.tipo = 'workshop';
  end if;

  if rv is not null and coalesce(pv, wk) is not null then
    perform public.gravar_evolucao(p_turma, p_user, 'completo', coalesce(pv, wk), case when pv is not null then wk end, rv);
  else
    delete from public.evolucoes e where e.turma_id = p_turma and e.user_id = p_user and e.tipo = 'completo' and e.status = 'rascunho';
  end if;
end;
$$;

-- 4. Pareamento automático a cada diagnóstico gravado --------------------------------------
create or replace function public.parear_evolucao()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  etapa text;
  ini uuid; ant uuid;
begin
  if new.turma_id is not null then
    etapa := public.etapa_turma(new.turma_id, (new.created_at at time zone 'America/Sao_Paulo')::date);
    -- Primeira execução da pessoa nesta etapa: relatório da turma. Uma execução extra na mesma etapa segue como individual.
    if etapa in ('workshop', 'reavaliacao') and not exists (
         select 1 from public.resultados r where r.user_id = new.user_id and r.turma_id = new.turma_id and r.id <> new.id
            and public.etapa_turma(new.turma_id, (r.created_at at time zone 'America/Sao_Paulo')::date) = etapa) then
      perform public.parear_pessoa_turma(new.user_id, new.turma_id);
      return new;
    end if;
  end if;
  -- Individual: quem já tem diagnóstico anterior
  select r.id into ini from public.resultados r where r.user_id = new.user_id and r.id <> new.id order by r.created_at asc limit 1;
  if ini is null then return new; end if;
  select r.id into ant from public.resultados r where r.user_id = new.user_id and r.id <> new.id order by r.created_at desc limit 1;
  perform public.gravar_evolucao(null, new.user_id, 'individual', ini, case when ant <> ini then ant end, new.id);
  return new;
end;
$$;

drop trigger if exists resultados_parear_evolucao on public.resultados;
create trigger resultados_parear_evolucao
  after insert on public.resultados
  for each row execute function public.parear_evolucao();

-- 5. Refazer os relatórios de uma turma (quando mudam as datas do workshop ou dos 45 dias) -----
drop function if exists public.parear_turma(uuid);
create function public.parear_turma(p_turma uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  u uuid;
  n integer := 0;
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  if not exists (select 1 from public.turmas where id = p_turma) then return 0; end if;
  for u in select distinct r.user_id from public.resultados r where r.turma_id = p_turma loop
    perform public.parear_pessoa_turma(u, p_turma);
  end loop;
  select count(*) into n from public.evolucoes e where e.turma_id = p_turma and e.tipo = 'completo';
  return n;
end;
$$;
drop function if exists public.pares_turma(uuid);

-- 6. Situação da reavaliação para a própria pessoa (relatório completo da turma) -------------
drop function if exists public.minha_reavaliacao();
create function public.minha_reavaliacao()
returns table (turma_id uuid, turma_nome text, reavaliar_em date, status text)
language sql stable security definer set search_path = public as $$
  select t.id, t.nome, t.reavaliar_em,
         (select e.status from public.evolucoes e where e.user_id = auth.uid() and e.turma_id = t.id and e.tipo = 'completo')
  from public.profiles p join public.turmas t on t.id = p.turma_id
  where p.id = auth.uid();
$$;

-- 7. Refaz os relatórios das turmas que já têm reavaliação, com as regras novas ----------------
do $$
declare r record;
begin
  for r in select distinct x.user_id, x.turma_id from public.resultados x join public.turmas t on t.id = x.turma_id loop
    perform public.parear_pessoa_turma(r.user_id, r.turma_id);
  end loop;
end $$;

revoke execute on function public.gravar_evolucao(uuid, uuid, text, uuid, uuid, uuid) from public, anon, authenticated;
revoke execute on function public.parear_pessoa_turma(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.parear_evolucao() from public, anon, authenticated;
grant execute on function public.parear_turma(uuid) to authenticated;
grant execute on function public.minha_reavaliacao() to authenticated;
