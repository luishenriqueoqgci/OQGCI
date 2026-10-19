-- Atualização 09 · patrocinador qualificado antes da venda
-- Rode uma vez no SQL Editor do Supabase (New query > colar este arquivo inteiro > Run), depois da atualização 08.
-- Pode ser rodado de novo sem problema: todos os comandos são repetíveis.
--
-- Regras:
-- - O facilitador qualifica uma pessoa como patrocinador (potencial ou já cliente) em Pessoas e acessos.
-- - O patrocinador qualificado responde o questionário antes de existir turma e vê o relatório dele na hora.
-- - Quando a venda fecha, o facilitador indica o patrocinador na turma, e o questionário respondido vai junto para a turma.
-- - Quem não é qualificado nem patrocinador de uma turma não grava questionário.

-- 1. Qualificação na pessoa -------------------------------------------------------------------
alter table public.profiles add column if not exists patrocinador boolean not null default false;
alter table public.profiles add column if not exists patrocinador_em timestamptz;
-- Quem já é patrocinador de alguma turma passa a ser qualificado.
update public.profiles p set patrocinador = true, patrocinador_em = coalesce(p.patrocinador_em, now())
 where not p.patrocinador and exists (select 1 from public.turmas t where t.patrocinador_id = p.id);

create or replace function public.is_patrocinador()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.patrocinador from public.profiles p where p.id = auth.uid()), false);
$$;
grant execute on function public.is_patrocinador() to authenticated;

-- 2. Questionário guardado na pessoa, com a turma preenchida depois -------------------------
alter table public.patrocinio_respostas add column if not exists id uuid not null default gen_random_uuid();
alter table public.patrocinio_respostas drop constraint if exists patrocinio_respostas_pkey;
alter table public.patrocinio_respostas add constraint patrocinio_respostas_pkey primary key (id);
alter table public.patrocinio_respostas alter column turma_id drop not null;
create unique index if not exists patrocinio_turma_pessoa_uq on public.patrocinio_respostas (turma_id, user_id) where turma_id is not null;
create unique index if not exists patrocinio_previa_uq on public.patrocinio_respostas (user_id) where turma_id is null;

drop policy if exists "patrocinio: patrocinador grava" on public.patrocinio_respostas;
create policy "patrocinio: patrocinador grava" on public.patrocinio_respostas
  for insert with check (user_id = auth.uid()
    and ((turma_id is null and public.is_patrocinador()) or (turma_id is not null and public.patrocina(turma_id))));
drop policy if exists "patrocinio: patrocinador altera" on public.patrocinio_respostas;
create policy "patrocinio: patrocinador altera" on public.patrocinio_respostas
  for update using (user_id = auth.uid() and ((turma_id is null and public.is_patrocinador()) or (turma_id is not null and public.patrocina(turma_id))))
  with check (user_id = auth.uid() and ((turma_id is null and public.is_patrocinador()) or (turma_id is not null and public.patrocina(turma_id))));

-- 3. Qualificar ou retirar a qualificação (só o facilitador) -------------------------------
drop function if exists public.definir_patrocinador_pessoa(uuid, boolean);
create function public.definir_patrocinador_pessoa(p_user uuid, p_valor boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  update public.profiles
     set patrocinador = coalesce(p_valor, false),
         patrocinador_em = case when coalesce(p_valor, false) then coalesce(patrocinador_em, now()) else null end
   where id = p_user;
end;
$$;
grant execute on function public.definir_patrocinador_pessoa(uuid, boolean) to authenticated;

-- 4. Indicar o patrocinador na turma: qualifica e leva o questionário já respondido ----------
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
  update public.profiles set patrocinador = true, patrocinador_em = coalesce(patrocinador_em, now()) where id = p.id;
  if not exists (select 1 from public.patrocinio_respostas r where r.turma_id = p_turma and r.user_id = p.id) then
    update public.patrocinio_respostas r set turma_id = p_turma where r.user_id = p.id and r.turma_id is null;
  end if;
  return query select 'ok'::text, p.nome, p.email;
end;
$$;
grant execute on function public.definir_patrocinador(uuid, text) to authenticated;

-- 5. Turmas que a pessoa patrocina, com a data das respostas dela ---------------------------
drop function if exists public.minhas_turmas_patrocinadas();
create function public.minhas_turmas_patrocinadas()
returns table (id uuid, nome text, data_workshop date, reavaliar_em date, respondido_em timestamptz)
language sql stable security definer set search_path = public as $$
  select t.id, t.nome, t.data_workshop, t.reavaliar_em, pr.updated_at
  from public.turmas t
  left join public.patrocinio_respostas pr on pr.turma_id = t.id and pr.user_id = auth.uid()
  where t.patrocinador_id = auth.uid() and coalesce(t.patrocinada, false)
  order by t.created_at desc;
$$;
grant execute on function public.minhas_turmas_patrocinadas() to authenticated;

-- 6. Lista de pessoas com a qualificação de patrocinador -----------------------------------
drop function if exists public.pessoas();
create function public.pessoas()
returns table (id uuid, nome text, email text, role text, created_at timestamptz, turma_id uuid, turma_nome text, turma_expira date,
               acesso_ate date, acesso_bloqueado boolean, pode boolean, motivo text, valido_ate date, diagnosticos bigint, ultimo timestamptz,
               nova_execucao boolean, limite_execucoes integer,
               pedido_id uuid, pedido_status text, pedido_motivo text, pedido_em timestamptz,
               patrocinador boolean, patro_respondido timestamptz, patro_turmas text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_facilitador() then raise exception 'not_allowed'; end if;
  return query
    select p.id, p.nome, p.email, p.role, p.created_at, a.turma_id, a.turma_nome, a.turma_expira,
           a.acesso_ate, a.acesso_bloqueado, a.pode, a.motivo, a.valido_ate,
           (select count(*) from public.resultados r where r.user_id = p.id),
           (select max(r.created_at) from public.resultados r where r.user_id = p.id),
           p.nova_execucao, p.limite_execucoes,
           pd.id, pd.status, pd.motivo, pd.created_at,
           p.patrocinador,
           (select max(pr.updated_at) from public.patrocinio_respostas pr where pr.user_id = p.id),
           (select string_agg(t.nome, ', ' order by t.created_at) from public.turmas t where t.patrocinador_id = p.id)
    from public.profiles p
    cross join lateral public.acesso_de(p.id) a
    left join lateral (select pe.id, pe.status, pe.motivo, pe.created_at from public.pedidos_execucao pe
                        where pe.user_id = p.id order by pe.created_at desc limit 1) pd on true
    order by p.created_at desc;
end;
$$;
grant execute on function public.pessoas() to authenticated;
