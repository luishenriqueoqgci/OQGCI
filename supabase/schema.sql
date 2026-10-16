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

-- 8. Evolução individual, opcional, por pessoa (mesmo conteúdo de atualizacao-05-evolucao-individual.sql) ---
-- 1. Data de reavaliação individual -------------------------------------------------
alter table public.profiles add column if not exists reavaliar_em date;

-- 2. Relatório individual: sem turma, um por pessoa ------------------------------------
alter table public.evolucoes alter column turma_id drop not null;
create unique index if not exists evolucoes_individual_uq on public.evolucoes (user_id) where turma_id is null;

-- 3. Pareamento automático: turma (como antes) e individual (quando habilitada) ---------
create or replace function public.parear_evolucao()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  t public.turmas%rowtype;
  ini uuid;
  dia date := (new.created_at at time zone 'America/Sao_Paulo')::date;
  data_ind date;
begin
  -- Turma
  if new.turma_id is not null then
    select * into t from public.turmas where id = new.turma_id;
    if t.reavaliar_em is not null and dia >= t.reavaliar_em then
      select r.id into ini from public.resultados r
       where r.user_id = new.user_id and r.turma_id = new.turma_id
         and (r.created_at at time zone 'America/Sao_Paulo')::date < t.reavaliar_em
       order by r.created_at desc limit 1;
      if ini is not null then
        insert into public.evolucoes (turma_id, user_id, inicial_id, reavaliacao_id)
        values (new.turma_id, new.user_id, ini, new.id)
        on conflict (turma_id, user_id) do update
          set inicial_id = excluded.inicial_id, reavaliacao_id = excluded.reavaliacao_id,
              status = 'rascunho', liberado_em = null, gerado_em = now();
      end if;
    end if;
  end if;

  -- Individual
  select p.reavaliar_em into data_ind from public.profiles p where p.id = new.user_id;
  if data_ind is not null and dia >= data_ind then
    ini := null;
    select r.id into ini from public.resultados r
     where r.user_id = new.user_id
       and (r.created_at at time zone 'America/Sao_Paulo')::date < data_ind
     order by r.created_at desc limit 1;
    if ini is not null then
      insert into public.evolucoes (turma_id, user_id, inicial_id, reavaliacao_id)
      values (null, new.user_id, ini, new.id)
      on conflict (user_id) where turma_id is null do update
        set inicial_id = excluded.inicial_id, reavaliacao_id = excluded.reavaliacao_id,
            status = 'rascunho', liberado_em = null, gerado_em = now();
    end if;
  end if;
  return new;
end;
$$;

-- 4. Par individual de uma pessoa ----------------------------------------------------
drop function if exists public.par_individual(uuid);
create function public.par_individual(p_user uuid)
returns table (inicial_id uuid, reavaliacao_id uuid)
language sql stable security definer set search_path = public as $$
  with d as (select reavaliar_em from public.profiles where id = p_user),
  rv as (
    select r.id from public.resultados r, d
    where r.user_id = p_user and d.reavaliar_em is not null
      and (r.created_at at time zone 'America/Sao_Paulo')::date >= d.reavaliar_em
    order by r.created_at desc limit 1
  )
  select * from (
    select (select r.id from public.resultados r, d
             where r.user_id = p_user
               and (r.created_at at time zone 'America/Sao_Paulo')::date < d.reavaliar_em
             order by r.created_at desc limit 1) as inicial_id,
           rv.id as reavaliacao_id
    from rv
  ) x where x.inicial_id is not null;
$$;

-- 5. Habilitar, alterar ou desativar a evolução individual (só o facilitador) ------------
-- p_data nula desativa. Relatório já liberado com o mesmo par continua liberado.
drop function if exists public.definir_reavaliacao_individual(uuid, date);
create function public.definir_reavaliacao_individual(p_user uuid, p_data date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  ini uuid; rea uuid;
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  update public.profiles set reavaliar_em = p_data where id = p_user;

  select p.inicial_id, p.reavaliacao_id into ini, rea from public.par_individual(p_user) p;
  if rea is null then
    delete from public.evolucoes e
     where e.user_id = p_user and e.turma_id is null and e.status = 'rascunho';
    return 0;
  end if;

  insert into public.evolucoes (turma_id, user_id, inicial_id, reavaliacao_id)
  values (null, p_user, ini, rea)
  on conflict (user_id) where turma_id is null do update
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
  return 1;
end;
$$;

-- 6. Lista de pessoas com a evolução individual -----------------------------------------
drop function if exists public.pessoas();
create function public.pessoas()
returns table (id uuid, nome text, email text, role text, created_at timestamptz, turma_id uuid, turma_nome text, turma_expira date,
               acesso_ate date, acesso_bloqueado boolean, pode boolean, motivo text, valido_ate date, diagnosticos bigint, ultimo timestamptz,
               reavaliar_em date, evo_status text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  return query
    select p.id, p.nome, p.email, p.role, p.created_at, a.turma_id, a.turma_nome, a.turma_expira,
           a.acesso_ate, a.acesso_bloqueado, a.pode, a.motivo, a.valido_ate,
           (select count(*) from public.resultados r where r.user_id = p.id),
           (select max(r.created_at) from public.resultados r where r.user_id = p.id),
           p.reavaliar_em,
           (select e.status from public.evolucoes e where e.user_id = p.id and e.turma_id is null)
    from public.profiles p cross join lateral public.acesso_de(p.id) a
    order by p.created_at desc;
end;
$$;

-- 7. Situação da reavaliação para a própria pessoa: turma e individual -------------------
drop function if exists public.minha_reavaliacao();
create function public.minha_reavaliacao()
returns table (turma_id uuid, turma_nome text, reavaliar_em date, status text)
language sql stable security definer set search_path = public as $$
  select t.id, t.nome, t.reavaliar_em,
         (select e.status from public.evolucoes e where e.user_id = auth.uid() and e.turma_id = t.id)
  from public.profiles p join public.turmas t on t.id = p.turma_id
  where p.id = auth.uid()
  union all
  select null::uuid, null::text, p.reavaliar_em,
         (select e.status from public.evolucoes e where e.user_id = auth.uid() and e.turma_id is null)
  from public.profiles p
  where p.id = auth.uid() and p.reavaliar_em is not null;
$$;

revoke execute on function public.parear_evolucao() from public, anon, authenticated;
revoke execute on function public.par_individual(uuid) from public, anon, authenticated;
grant execute on function public.definir_reavaliacao_individual(uuid, date) to authenticated;
grant execute on function public.pessoas() to authenticated;
grant execute on function public.minha_reavaliacao() to authenticated;
