-- Fibre Hunter: "Top 3 this week" upgrade. Safe to run more than once.
-- Adds a log of every posted run, so the game can rank this week's best scores.

create table if not exists public.runs (
  id          bigint generated always as identity primary key,
  player      uuid not null,
  score       integer not null check (score >= 0),
  reached     text not null default '1-1' check (char_length(reached) <= 6),
  created_at  timestamptz not null default now()
);
create index if not exists runs_created_at_idx on public.runs (created_at);
create index if not exists runs_player_idx on public.runs (player);

-- Nobody reads or writes runs directly; only the two functions below touch it.
alter table public.runs enable row level security;

-- Same as before, plus it records each posted run.
create or replace function public.submit_score(
  p_id uuid,
  p_tag text,
  p_team text,
  p_score integer,
  p_reached text,
  p_count_run boolean default true
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_best integer;
begin
  if p_id is null then
    raise exception 'player id required';
  end if;
  if p_score is null or p_score < 0 or p_score > 10000000 then
    raise exception 'score out of range';
  end if;

  p_tag := left(btrim(coalesce(p_tag, '')), 14);
  if p_tag = '' then p_tag := 'ANON'; end if;
  p_team := left(btrim(coalesce(p_team, '')), 20);
  p_reached := left(coalesce(nullif(btrim(p_reached), ''), '1-1'), 6);

  insert into public.scores as s (id, tag, team, best, reached, runs, updated_at)
  values (p_id, p_tag, p_team, p_score, p_reached,
          case when p_count_run then 1 else 0 end, now())
  on conflict (id) do update set
    tag        = excluded.tag,
    team       = excluded.team,
    reached    = case when excluded.best > s.best then excluded.reached else s.reached end,
    best       = greatest(s.best, excluded.best),
    runs       = s.runs + case when p_count_run then 1 else 0 end,
    updated_at = now()
  returning best into v_best;

  insert into public.runs (player, score, reached) values (p_id, p_score, p_reached);

  return v_best;
end;
$$;

revoke all on function public.submit_score(uuid, text, text, integer, text, boolean) from public;
grant execute on function public.submit_score(uuid, text, text, integer, text, boolean) to anon, authenticated;

-- Each player's best run since Monday 00:00 New Zealand time, highest first.
create or replace function public.weekly_top(p_limit integer default 3)
returns table (id uuid, tag text, team text, best integer, reached text)
language sql
stable
security definer
set search_path = public
as $$
  with wk as (
    select (date_trunc('week', now() at time zone 'Pacific/Auckland')) at time zone 'Pacific/Auckland' as start
  ),
  ranked as (
    select r.player, r.score, r.reached,
           row_number() over (partition by r.player order by r.score desc, r.created_at asc) as rn
    from public.runs r, wk
    where r.created_at >= wk.start
  )
  select s.id, s.tag, s.team, k.score, k.reached
  from ranked k
  join public.scores s on s.id = k.player
  where k.rn = 1
  order by k.score desc
  limit greatest(1, least(coalesce(p_limit, 3), 10));
$$;

revoke all on function public.weekly_top(integer) from public;
grant execute on function public.weekly_top(integer) to anon, authenticated;
