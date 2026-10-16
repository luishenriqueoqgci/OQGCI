-- Atualização 05 · evolução individual, opcional, por pessoa
-- Rode uma vez no SQL Editor do Supabase (New query > colar este arquivo inteiro > Run), depois das atualizações 03 e 04.
-- Pode ser rodado de novo sem problema: todos os comandos são repetíveis.
--
-- Regras:
-- - A evolução automática continua pela turma (atualização 03), sem mudança.
-- - Em Pessoas e acessos, o facilitador pode habilitar a evolução individual de uma pessoa, com uma data de reavaliação só dela.
-- - Diagnóstico inicial: o último diagnóstico da pessoa antes dessa data, com ou sem turma.
-- - Reavaliação: o último diagnóstico da pessoa a partir dessa data.
-- - O relatório é gerado como rascunho; o facilitador revisa, comenta e libera, como na turma.
-- - Desativar remove a data e descarta o rascunho; um relatório já liberado continua com a pessoa.
-- As datas seguem o horário de Brasília.

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
