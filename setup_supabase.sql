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
  violations jsonb not null default '[]'::jsonb,
  close_events jsonb not null default '[]'::jsonb
);

alter table public.tentativas enable row level security;

-- Não existe nenhuma policy de insert/update direto para "anon": toda
-- escrita (criar, retomar, registrar tentativa de fraude, finalizar)
-- passa por funções "security definer" (definidas mais abaixo), que
-- ignoram RLS por completo e não dependem de a policy "to anon" ser
-- interpretada corretamente pelo PostgREST — o que se mostrou não
-- funcionar de forma confiável com o tipo de chave usado neste projeto.

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
      'close_events', v_row.close_events,
      'started_at', v_row.started_at
    );
  end if;

  return jsonb_build_object('action', 'blocked');
end;
$$;

grant execute on function public.iniciar_ou_retomar_tentativa(text, text, text) to anon;

-- ---------------------------------------------------------------------
-- Sincronizar tentativa: grava as tentativas de fraude em tempo real, e
-- opcionalmente o status final (concluida/bloqueada). p_status e
-- p_ended_at só sobrescrevem o valor existente quando informados (não
-- nulos) — assim a mesma função serve tanto para o registro de cada
-- tentativa de burla quanto para a finalização da prova.
-- ---------------------------------------------------------------------

-- Remove a versão anterior da função (assinatura antiga, sem close_events)
-- para não deixar duas versões sobrepostas no banco.
drop function if exists public.sincronizar_tentativa(uuid, integer, jsonb, text, timestamptz);

create or replace function public.sincronizar_tentativa(
  p_id uuid,
  p_violations_count integer,
  p_violations jsonb,
  p_close_events jsonb default null,
  p_status text default null,
  p_ended_at timestamptz default null
)
returns void
language sql
security definer
set search_path = public
as $$
  update public.tentativas
  set violations_count = p_violations_count,
      violations = p_violations,
      close_events = coalesce(p_close_events, close_events),
      status = coalesce(p_status, status),
      ended_at = coalesce(p_ended_at, ended_at)
  where id = p_id;
$$;

grant execute on function public.sincronizar_tentativa(uuid, integer, jsonb, jsonb, text, timestamptz) to anon;

-- Depois de rodar este script, insira os alunos autorizados, por exemplo:
-- insert into public.alunos_permitidos (nome_turma_key, nome, turma) values
--   (public.normalize_text('Maria Silva') || '|' || public.normalize_text('3º Ano B'), 'Maria Silva', '3º Ano B'),
--   (public.normalize_text('João Souza') || '|' || public.normalize_text('3º Ano B'), 'João Souza', '3º Ano B');
