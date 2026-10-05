-- Per-user rate limits for the OpenAI-backed edge functions.
--
-- Every function call that would hit OpenAI first calls consume_ai_quota(),
-- which atomically checks the user's recent usage and records this call.
-- Only the edge functions (service_role) can call it or see the table, so a
-- client can't reset or read its own counters.

create table public.ai_usage (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  kind text not null check (kind in ('suggest', 'image')),
  created_at timestamptz not null default now()
);
create index ai_usage_user_kind_time on public.ai_usage (user_id, kind, created_at desc);

alter table public.ai_usage enable row level security;   -- no policies: service_role only
grant all on public.ai_usage to service_role;

-- Returns null when the call is allowed (and records it), otherwise a short
-- human-readable reason to show the user.
create or replace function public.consume_ai_quota(p_user uuid, p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  -- (window, max calls) pairs: a burst limit and a daily limit per kind.
  v_burst_window interval;
  v_burst_max int;
  v_day_max int;
  v_recent int;
  v_today int;
begin
  case p_kind
    when 'suggest' then v_burst_window := interval '10 minutes'; v_burst_max := 40; v_day_max := 300;
    when 'image'   then v_burst_window := interval '1 hour';     v_burst_max := 8;  v_day_max := 30;
    else raise exception 'unknown quota kind %', p_kind;
  end case;

  -- Serialise concurrent calls for the same user+kind so bursts can't race past the limit.
  perform pg_advisory_xact_lock(hashtextextended(p_user::text || ':' || p_kind, 0));

  select count(*) filter (where created_at > now() - v_burst_window),
         count(*)
    into v_recent, v_today
    from public.ai_usage
   where user_id = p_user and kind = p_kind and created_at > now() - interval '1 day';

  if v_recent >= v_burst_max then
    return case p_kind when 'image' then 'Lamar has taken a lot of photos lately. Try again in a bit.'
                       else 'Lamar needs a breather. Try again in a few minutes.' end;
  end if;
  if v_today >= v_day_max then
    return case p_kind when 'image' then 'That''s enough photos for today. Lamar will be back tomorrow.'
                       else 'Lamar is out of ideas for today. Try again tomorrow.' end;
  end if;

  insert into public.ai_usage (user_id, kind) values (p_user, p_kind);
  -- Keep the table small: nothing older than a day matters.
  delete from public.ai_usage where user_id = p_user and kind = p_kind and created_at < now() - interval '2 days';
  return null;
end;
$$;

revoke execute on function public.consume_ai_quota(uuid, text) from public, anon, authenticated;
grant execute on function public.consume_ai_quota(uuid, text) to service_role;
