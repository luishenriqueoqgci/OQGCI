-- Atualização 07 · relatório de evolução por etapas (prévia, workshop e 45 dias) e evolução individual a cada nova execução
-- Rode uma vez no SQL Editor do Supabase (New query > colar este arquivo inteiro > Run), depois da atualização 06.
-- Pode ser rodado de novo sem problema: todos os comandos são repetíveis.
--
-- Regras:
-- Turma
-- - Execução no dia do workshop, com prévia feita: gera o relatório prévia -> workshop, de uso interno do facilitador (nunca liberado).
-- - Execução a partir dos 45 dias: gera o relatório completo prévia -> workshop -> 45 dias, em rascunho para revisão e liberação.
--   Sem prévia, o completo compara workshop -> 45 dias; turma sem data de workshop compara inicial -> reavaliação.
-- Individual
-- - Qualquer outra execução de quem já tem diagnóstico anterior (inclusive uma execução extra liberada depois dos 45 dias)
--   gera um relatório individual em rascunho:
--   primeira execução -> execução anterior -> execução atual.
-- As datas seguem o horário de Brasília.

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
