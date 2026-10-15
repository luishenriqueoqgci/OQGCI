-- Atualização 03 · relatório de evolução (diagnóstico inicial x reavaliação)
-- Rode uma vez no SQL Editor do Supabase (New query > colar este arquivo inteiro > Run).
-- Pode ser rodado de novo sem problema: todos os comandos são repetíveis.
--
-- Regras:
-- - Cada turma pode ter uma data de reavaliação.
-- - Diagnóstico inicial: o último diagnóstico da pessoa na turma antes dessa data.
-- - Reavaliação: o último diagnóstico da pessoa na turma a partir dessa data.
-- - Ao gravar uma reavaliação, o banco gera o par automaticamente, como rascunho.
-- - Só o facilitador vê o rascunho; ele revisa, comenta e libera.
-- - A pessoa vê o relatório de evolução apenas depois de liberado.
-- As datas seguem o horário de Brasília.

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
drop function if exists public.parear_turma(uuid);
create function public.parear_turma(p_turma uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  t public.turmas%rowtype;
  n integer := 0;
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  select * into t from public.turmas where id = p_turma;
  if not found then return 0; end if;
  if t.reavaliar_em is null then
    delete from public.evolucoes where turma_id = p_turma and status = 'rascunho';
    return 0;
  end if;

  create temp table if not exists _pares (user_id uuid, inicial_id uuid, reavaliacao_id uuid) on commit drop;
  delete from _pares;
  insert into _pares (user_id, inicial_id, reavaliacao_id)
  select rv.user_id,
         (select r.id from public.resultados r
           where r.user_id = rv.user_id and r.turma_id = p_turma
             and (r.created_at at time zone 'America/Sao_Paulo')::date < t.reavaliar_em
           order by r.created_at desc limit 1),
         rv.id
  from (
    select distinct on (r.user_id) r.user_id, r.id
    from public.resultados r
    where r.turma_id = p_turma
      and (r.created_at at time zone 'America/Sao_Paulo')::date >= t.reavaliar_em
    order by r.user_id, r.created_at desc
  ) rv;
  delete from _pares where inicial_id is null;

  delete from public.evolucoes e
   where e.turma_id = p_turma and e.status = 'rascunho'
     and not exists (select 1 from _pares p where p.user_id = e.user_id);

  insert into public.evolucoes (turma_id, user_id, inicial_id, reavaliacao_id)
  select p_turma, p.user_id, p.inicial_id, p.reavaliacao_id from _pares p
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

  select count(*) into n from _pares;
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
