-- Rode este script no Supabase: Dashboard do seu projeto > SQL Editor > New query > cole tudo > Run

create table if not exists public.tentativas (
  id uuid primary key default gen_random_uuid(),
  nome_turma_key text not null unique,
  nome text not null,
  turma text not null,
  started_at timestamptz not null default now()
);

alter table public.tentativas enable row level security;

create policy "Permitir inserção pública de tentativas"
on public.tentativas
for insert
to anon
with check (true);
