-- Rode este script no Supabase: Dashboard do seu projeto > SQL Editor > New query > cole tudo > Run
-- Como a prova agora exige e-mail, a chave de unicidade trocou de nome+turma para e-mail.
-- Se você já tinha rodado a versão anterior deste script, este comando substitui a tabela
-- antiga (e as poucas tentativas de teste que já existiam nela).

drop table if exists public.tentativas;

create table public.tentativas (
  id uuid primary key default gen_random_uuid(),
  email_key text not null unique,
  nome text not null,
  turma text not null,
  email text not null,
  started_at timestamptz not null default now()
);

alter table public.tentativas enable row level security;

create policy "Permitir inserção pública de tentativas"
on public.tentativas
for insert
to anon
with check (true);

-- ---------------------------------------------------------------------
-- Lista de alunos autorizados: só quem está aqui consegue iniciar a prova.
-- ---------------------------------------------------------------------

create extension if not exists unaccent;

create or replace function public.normalize_text(input text)
returns text
language sql
immutable
as $$
  select regexp_replace(lower(trim(unaccent(coalesce(input, '')))), '\s+', ' ', 'g');
$$;

create table if not exists public.alunos_permitidos (
  id uuid primary key default gen_random_uuid(),
  nome_turma_key text not null unique,
  nome text not null,
  turma text not null
);

-- RLS ligado e sem nenhuma policy para "anon": ninguém consegue ler a lista
-- completa de alunos diretamente. A única forma de consultar é através da
-- função abaixo, que só devolve true/false (nunca a lista inteira).
alter table public.alunos_permitidos enable row level security;

create or replace function public.is_aluno_permitido(p_nome text, p_turma text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.alunos_permitidos
    where nome_turma_key = normalize_text(p_nome) || '|' || normalize_text(p_turma)
  );
$$;

grant execute on function public.is_aluno_permitido(text, text) to anon;

-- Depois de rodar este script, insira os alunos autorizados, por exemplo:
-- insert into public.alunos_permitidos (nome_turma_key, nome, turma) values
--   (public.normalize_text('Maria Silva') || '|' || public.normalize_text('3º Ano B'), 'Maria Silva', '3º Ano B'),
--   (public.normalize_text('João Souza') || '|' || public.normalize_text('3º Ano B'), 'João Souza', '3º Ano B');
