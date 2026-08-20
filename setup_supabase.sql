-- Rode este script no Supabase: Dashboard do seu projeto > SQL Editor > New query > cole tudo > Run
-- O bloqueio de tentativa repetida é por nome+turma (mesma chave usada na lista de
-- autorizados). O e-mail continua sendo coletado e salvo, só não faz parte da
-- trava de tentativa única. Se você já tinha rodado uma versão anterior deste
-- script, este comando substitui a tabela antiga (e as tentativas de teste nela).

drop table if exists public.tentativas;

create table public.tentativas (
  id uuid primary key default gen_random_uuid(),
  nome_turma_key text not null unique,
  nome text not null,
  turma text not null,
  email text not null,
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  status text not null default 'em_andamento',
  violations_count integer not null default 0,
  violations jsonb not null default '[]'::jsonb
);

alter table public.tentativas enable row level security;

-- Não existe policy de insert direto: toda criação/retomada de tentativa
-- passa pela função iniciar_ou_retomar_tentativa (definida mais abaixo),
-- que decide se cria uma tentativa nova, retoma uma em andamento, ou
-- bloqueia — sem isso, qualquer um poderia inserir linhas falsas sem
-- passar pela checagem da lista de alunos autorizados.

-- Permite que o navegador do aluno atualize a própria linha (para registrar
-- tentativas de fraude e o status final) usando o id devolvido no insert.
-- Sem sistema de login não dá para restringir isso à "linha do próprio aluno"
-- de forma criptograficamente segura — mas o id é um UUID aleatório que só
-- o navegador do aluno recebe, então na prática só ele consegue atualizar
-- a própria linha.
create policy "Permitir atualização pública de tentativas"
on public.tentativas
for update
to anon
using (true)
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

-- ---------------------------------------------------------------------
-- Iniciar ou retomar tentativa: fechar a aba não deve zerar as tentativas
-- nem bloquear o aluno para sempre. Esta função decide, para um dado
-- nome+turma:
--   - "new"     -> nenhuma tentativa existia, cria uma nova (zerada).
--   - "resume"  -> já existia uma tentativa em andamento (aba fechada no
--                  meio da prova); devolve o id e as tentativas de burla
--                  já registradas, para o navegador continuar de onde parou.
--   - "blocked" -> a tentativa já foi concluída ou bloqueada de vez.
-- ---------------------------------------------------------------------

create or replace function public.iniciar_ou_retomar_tentativa(p_nome text, p_turma text, p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text;
  v_row public.tentativas;
  v_new_id uuid;
begin
  v_key := normalize_text(p_nome) || '|' || normalize_text(p_turma);

  select * into v_row from public.tentativas where nome_turma_key = v_key;

  if not found then
    v_new_id := gen_random_uuid();
    insert into public.tentativas (id, nome_turma_key, nome, turma, email)
    values (v_new_id, v_key, p_nome, p_turma, p_email);
    return jsonb_build_object('action', 'new', 'id', v_new_id);
  end if;

  if v_row.status = 'em_andamento' and v_row.violations_count < 3 then
    return jsonb_build_object(
      'action', 'resume',
      'id', v_row.id,
      'violations', v_row.violations,
      'started_at', v_row.started_at
    );
  end if;

  return jsonb_build_object('action', 'blocked');
end;
$$;

grant execute on function public.iniciar_ou_retomar_tentativa(text, text, text) to anon;

-- Depois de rodar este script, insira os alunos autorizados, por exemplo:
-- insert into public.alunos_permitidos (nome_turma_key, nome, turma) values
--   (public.normalize_text('Maria Silva') || '|' || public.normalize_text('3º Ano B'), 'Maria Silva', '3º Ano B'),
--   (public.normalize_text('João Souza') || '|' || public.normalize_text('3º Ano B'), 'João Souza', '3º Ano B');
