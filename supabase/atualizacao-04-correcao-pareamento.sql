-- Atualização 04 · correção do pareamento da evolução
-- Rode uma vez no SQL Editor do Supabase (New query > colar este arquivo inteiro > Run), depois da atualização 03.
-- Corrige o erro "DELETE requires a WHERE clause" ao definir a data de reavaliação da turma.

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

revoke execute on function public.pares_turma(uuid) from public, anon, authenticated;
grant execute on function public.parear_turma(uuid) to authenticated;
