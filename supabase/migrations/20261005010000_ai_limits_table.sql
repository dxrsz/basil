-- Table-driven AI rate limits, so new AI features only add a row here instead
-- of rewriting consume_ai_quota (several features are being built in parallel).
--
-- Edit limits in Supabase → Table Editor → ai_limits; changes apply at once.
-- global_per_day = 0 switches a feature off for everyone.

create table public.ai_limits (
  kind text primary key,
  burst_window interval not null,
  burst_max int not null check (burst_max >= 0),
  user_per_day int not null check (user_per_day >= 0),
  global_per_day int not null check (global_per_day >= 0),
  -- Shown to the user (in Lamar's voice) when a limit is hit.
  burst_message text not null default 'Lamar needs a breather. Try again in a few minutes.',
  user_day_message text not null default 'Lamar is out of steam for today. Try again tomorrow.',
  global_message text not null default 'Lamar is resting for the day. Try again tomorrow.'
);

insert into public.ai_limits (kind, burst_window, burst_max, user_per_day, global_per_day,
                              burst_message, user_day_message, global_message) values
  ('suggest', '10 minutes', 40, 300, coalesce((select per_day from public.ai_global_limits where kind = 'suggest'), 3000),
   'Lamar needs a breather. Try again in a few minutes.',
   'Lamar is out of ideas for today. Try again tomorrow.',
   'Lamar is resting for the day. Suggestions will be back tomorrow.'),
  ('image', '1 hour', 8, 30, coalesce((select per_day from public.ai_global_limits where kind = 'image'), 300),
   'Lamar has taken a lot of photos lately. Try again in a bit.',
   'That''s enough photos for today. Lamar will be back tomorrow.',
   'Lamar has taken all the photos he can for today. Try again tomorrow.'),
  -- Meal planner: plan my week, swaps/nudges, "what can I make tonight?"
  ('plan', '10 minutes', 30, 150, 3000,
   'Lamar is still mulling over the last plan. Try again in a few minutes.',
   'Lamar has planned plenty for today. Try again tomorrow.',
   'Lamar''s planning desk is closed for today. Try again tomorrow.'),
  -- Smart list cleanup (merge duplicates, combine quantities)
  ('tidy', '10 minutes', 20, 100, 2000,
   'Lamar just tidied up. Try again in a few minutes.',
   'Lamar has done enough tidying for today.',
   'Lamar''s tidying is done for the day. Try again tomorrow.'),
  -- Snap or paste to add (vision on photos, recipe URLs)
  ('import', '10 minutes', 10, 60, 1000,
   'Lamar is still reading the last one. Try again in a few minutes.',
   'Lamar has read enough for today. Try again tomorrow.',
   'Lamar''s reading glasses are off for today. Try again tomorrow.');

alter table public.ai_limits enable row level security;   -- service_role only
grant all on public.ai_limits to service_role;

-- ai_usage.kind now must be a configured kind.
alter table public.ai_usage drop constraint if exists ai_usage_kind_check;
alter table public.ai_usage
  add constraint ai_usage_kind_fkey foreign key (kind) references public.ai_limits (kind) on update cascade;

drop table public.ai_global_limits;

-- Returns null when the call is allowed (and records it), otherwise the
-- message to show the user.
create or replace function public.consume_ai_quota(p_user uuid, p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  l public.ai_limits%rowtype;
  v_global int;
  v_recent int;
  v_today int;
begin
  select * into l from public.ai_limits where kind = p_kind;
  if not found then
    raise exception 'unknown AI quota kind %; add a row to ai_limits', p_kind;
  end if;

  -- Serialise per kind so concurrent calls can't race past either limit.
  perform pg_advisory_xact_lock(hashtextextended('ai_quota:' || p_kind, 0));

  select count(*) into v_global
    from public.ai_usage where kind = p_kind and created_at > now() - interval '1 day';
  if v_global >= l.global_per_day then
    return l.global_message;
  end if;

  select count(*) filter (where created_at > now() - l.burst_window), count(*)
    into v_recent, v_today
    from public.ai_usage
   where user_id = p_user and kind = p_kind and created_at > now() - interval '1 day';
  if v_recent >= l.burst_max then
    return l.burst_message;
  end if;
  if v_today >= l.user_per_day then
    return l.user_day_message;
  end if;

  insert into public.ai_usage (user_id, kind) values (p_user, p_kind);
  delete from public.ai_usage where kind = p_kind and created_at < now() - interval '2 days';
  return null;
end;
$$;

revoke execute on function public.consume_ai_quota(uuid, text) from public, anon, authenticated;
grant execute on function public.consume_ai_quota(uuid, text) to service_role;
