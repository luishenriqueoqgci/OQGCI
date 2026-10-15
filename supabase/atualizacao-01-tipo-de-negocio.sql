-- Atualização 01 · pergunta do tipo de negócio por turma
-- Rode uma vez no SQL Editor do Supabase (New query > colar > Run).
alter table public.turmas add column if not exists perguntar_nicho boolean not null default true;

drop function if exists public.turma_por_codigo(text);
create function public.turma_por_codigo(p_codigo text)
returns table (id uuid, nome text, perguntar_nicho boolean) language sql stable security definer set search_path = public as $$
  select t.id, t.nome, t.perguntar_nicho from public.turmas t where upper(t.codigo) = upper(trim(p_codigo)) limit 1;
$$;
grant execute on function public.turma_por_codigo(text) to authenticated;
