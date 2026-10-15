-- Atualização 02 · controle de acesso por turma e por pessoa
-- Rode uma vez no SQL Editor do Supabase (New query > colar este arquivo inteiro > Run).
--
-- Regras:
-- - Para gerar um novo diagnóstico, a pessoa precisa de acesso ativo.
-- - Acesso por turma: a pessoa entra com o código da turma; vale até a data de validade da turma (sem data = sem prazo).
-- - Acesso individual: o facilitador libera a pessoa até uma data; vale mesmo sem turma ou com a turma vencida.
-- - Encerrar acesso: bloqueia novos diagnósticos da pessoa, mesmo com turma ou data válidas.
-- - Relatórios já gerados continuam visíveis e disponíveis para download pela própria pessoa.
-- - Facilitadores sempre têm acesso.
-- As datas seguem o horário de Brasília e valem até o fim do dia informado.

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
