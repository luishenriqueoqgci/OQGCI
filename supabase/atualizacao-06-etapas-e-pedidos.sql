-- Atualização 06 · etapas da turma, turma patrocinada e pedidos de nova execução
-- Rode uma vez no SQL Editor do Supabase (New query > colar este arquivo inteiro > Run), depois da atualização 05.
-- Pode ser rodado de novo sem problema: todos os comandos são repetíveis.
--
-- Regras:
-- Turma
-- - Toda turma pode ter uma data de workshop e uma data de reavaliação (45 dias).
-- - Etapas: prévia (antes do workshop), workshop (no dia), intervalo (entre o workshop e os 45 dias) e reavaliação (a partir dos 45 dias).
-- - Cada pessoa faz uma execução por etapa. No intervalo, ninguém executa.
-- - Turma sem data de workshop: uma execução antes da data de reavaliação e uma a partir dela.
-- - Turma patrocinada: marca a turma contratada por uma empresa (a área do patrocinador vem numa próxima atualização).
-- Individual
-- - Cada pessoa tem direito a uma execução no total, dentro da data de acesso individual ("Liberar até").
-- - O facilitador pode permitir novas execuções com um limite total; ao atingir o limite, a permissão é desligada sozinha.
-- - A pessoa sem execução disponível pode pedir uma nova, explicando o motivo; o facilitador libera ou recusa, com uma resposta que a pessoa vê no app.
-- Evolução
-- - A evolução individual por data (atualização 05) é retirada; a evolução da turma segue como está.
-- As datas seguem o horário de Brasília.

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
