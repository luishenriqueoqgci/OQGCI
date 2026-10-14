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
  facilitador_id uuid references public.profiles (id) on delete set null default auth.uid(),
  created_at timestamptz not null default now()
);

-- Busca de turma pelo código, sem expor a lista de turmas aos respondentes
create or replace function public.turma_por_codigo(p_codigo text)
returns table (id uuid, nome text) language sql stable security definer set search_path = public as $$
  select t.id, t.nome from public.turmas t where upper(t.codigo) = upper(trim(p_codigo)) limit 1;
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
