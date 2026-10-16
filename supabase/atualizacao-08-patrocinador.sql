-- Atualização 08 · área do patrocinador (turma patrocinada)
-- Rode uma vez no SQL Editor do Supabase (New query > colar este arquivo inteiro > Run), depois da atualização 07.
-- Pode ser rodado de novo sem problema: todos os comandos são repetíveis.
--
-- Regras:
-- - Numa turma patrocinada, o facilitador indica o patrocinador pelo e-mail da conta dele no app.
-- - O patrocinador responde o questionário de dores do negócio e vê o relatório dele logo depois.
-- - Os relatórios do time para o patrocinador (prévia, workshop e 45 dias) são consolidados e anônimos:
--   o facilitador gera o retrato agregado da turma, revisa e libera. O patrocinador nunca lê diagnósticos individuais.
-- - O mínimo de 5 pessoas por etapa é conferido pelo app na geração do relatório.

-- 1. Patrocinador da turma -------------------------------------------------------------------
alter table public.turmas add column if not exists patrocinador_id uuid references public.profiles (id) on delete set null;

-- A pessoa é patrocinadora desta turma? (o patrocinador não lê a tabela de turmas)
create or replace function public.patrocina(p_turma uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.turmas t where t.id = p_turma and t.patrocinador_id = auth.uid());
$$;
grant execute on function public.patrocina(uuid) to authenticated;

-- 2. Respostas do questionário do patrocinador ------------------------------------------------
create table if not exists public.patrocinio_respostas (
  turma_id uuid primary key references public.turmas (id) on delete cascade,
  user_id uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  respostas jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.patrocinio_respostas enable row level security;
drop policy if exists "patrocinio: ler" on public.patrocinio_respostas;
create policy "patrocinio: ler" on public.patrocinio_respostas
  for select using (public.is_facilitador() or user_id = auth.uid());
drop policy if exists "patrocinio: patrocinador grava" on public.patrocinio_respostas;
create policy "patrocinio: patrocinador grava" on public.patrocinio_respostas
  for insert with check (user_id = auth.uid() and public.patrocina(turma_id));
drop policy if exists "patrocinio: patrocinador altera" on public.patrocinio_respostas;
create policy "patrocinio: patrocinador altera" on public.patrocinio_respostas
  for update using (user_id = auth.uid() and public.patrocina(turma_id))
  with check (user_id = auth.uid() and public.patrocina(turma_id));
drop policy if exists "patrocinio: facilitador remove" on public.patrocinio_respostas;
create policy "patrocinio: facilitador remove" on public.patrocinio_respostas
  for delete using (public.is_facilitador());
grant select, insert, update, delete on public.patrocinio_respostas to authenticated;

-- 3. Relatórios do time para o patrocinador (dados agregados, sem nomes) ----------------------
create table if not exists public.relatorios_patrocinador (
  id uuid primary key default gen_random_uuid(),
  turma_id uuid not null references public.turmas (id) on delete cascade,
  etapa text not null check (etapa in ('previa', 'workshop', 'reavaliacao')),
  dados jsonb not null,
  comentario text,
  status text not null default 'rascunho' check (status in ('rascunho', 'liberado')),
  gerado_em timestamptz not null default now(),
  liberado_em timestamptz,
  unique (turma_id, etapa)
);
alter table public.relatorios_patrocinador enable row level security;
drop policy if exists "relatorios_patrocinador: facilitador gerencia" on public.relatorios_patrocinador;
create policy "relatorios_patrocinador: facilitador gerencia" on public.relatorios_patrocinador
  for all using (public.is_facilitador()) with check (public.is_facilitador());
drop policy if exists "relatorios_patrocinador: patrocinador lê liberado" on public.relatorios_patrocinador;
create policy "relatorios_patrocinador: patrocinador lê liberado" on public.relatorios_patrocinador
  for select using (status = 'liberado' and public.patrocina(turma_id));
grant select, insert, update, delete on public.relatorios_patrocinador to authenticated;

-- 4. Turmas que a pessoa patrocina (o patrocinador não lê a tabela de turmas) ------------------
drop function if exists public.minhas_turmas_patrocinadas();
create function public.minhas_turmas_patrocinadas()
returns table (id uuid, nome text, data_workshop date, reavaliar_em date, respondido_em timestamptz)
language sql stable security definer set search_path = public as $$
  select t.id, t.nome, t.data_workshop, t.reavaliar_em, pr.updated_at
  from public.turmas t left join public.patrocinio_respostas pr on pr.turma_id = t.id
  where t.patrocinador_id = auth.uid() and coalesce(t.patrocinada, false)
  order by t.created_at desc;
$$;

-- 5. Indicar o patrocinador pelo e-mail da conta (só o facilitador) ----------------------------
drop function if exists public.definir_patrocinador(uuid, text);
create function public.definir_patrocinador(p_turma uuid, p_email text)
returns table (status text, nome text, email text)
language plpgsql security definer set search_path = public as $$
declare p public.profiles%rowtype;
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  if p_email is null or trim(p_email) = '' then
    update public.turmas set patrocinador_id = null where public.turmas.id = p_turma;
    return query select 'removido'::text, null::text, null::text; return;
  end if;
  select * into p from public.profiles pf where lower(pf.email) = lower(trim(p_email)) limit 1;
  if p.id is null then return query select 'nao_encontrado'::text, null::text, null::text; return; end if;
  update public.turmas set patrocinador_id = p.id, patrocinada = true where public.turmas.id = p_turma;
  return query select 'ok'::text, p.nome, p.email;
end;
$$;

grant execute on function public.minhas_turmas_patrocinadas() to authenticated;
grant execute on function public.definir_patrocinador(uuid, text) to authenticated;
