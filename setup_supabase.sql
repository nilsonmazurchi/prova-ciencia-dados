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
