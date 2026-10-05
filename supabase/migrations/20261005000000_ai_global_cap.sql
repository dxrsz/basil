-- Global daily caps on OpenAI-backed calls, across all users: a kill switch
-- that bounds spend no matter how many accounts are involved (per-user limits
-- alone can be multiplied by signing up more accounts).
--
-- Edit the numbers in Supabase → Table Editor → ai_global_limits; changes take
-- effect immediately. Set per_day to 0 to switch a feature off entirely.

create table public.ai_global_limits (
  kind text primary key check (kind in ('suggest', 'image')),
  per_day int not null check (per_day >= 0)
);
insert into public.ai_global_limits (kind, per_day) values
  ('suggest', 3000),   -- ~$0.50/day at gpt-5-mini with minimal reasoning
  ('image', 300);      -- ~$12/day at gpt-image-1, 1024², medium quality

alter table public.ai_global_limits enable row level security;   -- service_role only
grant all on public.ai_global_limits to service_role;

create index ai_usage_kind_time on public.ai_usage (kind, created_at desc);

create or replace function public.consume_ai_quota(p_user uuid, p_kind text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_burst_window interval;
  v_burst_max int;
  v_day_max int;
  v_global_max int;
  v_recent int;
  v_today int;
  v_global int;
begin
  case p_kind
    when 'suggest' then v_burst_window := interval '10 minutes'; v_burst_max := 40; v_day_max := 300;
    when 'image'   then v_burst_window := interval '1 hour';     v_burst_max := 8;  v_day_max := 30;
    else raise exception 'unknown quota kind %', p_kind;
  end case;

  -- Serialise per kind (not just per user) so concurrent calls from different
  -- users can't race past the global cap either. Volume is low; contention is fine.
  perform pg_advisory_xact_lock(hashtextextended('ai_quota:' || p_kind, 0));

  select coalesce((select per_day from public.ai_global_limits where kind = p_kind), 0)
    into v_global_max;
  select count(*) into v_global
    from public.ai_usage
   where kind = p_kind and created_at > now() - interval '1 day';
  if v_global >= v_global_max then
    return case p_kind when 'image' then 'Lamar has taken all the photos he can for today. Try again tomorrow.'
                       else 'Lamar is resting for the day. Suggestions will be back tomorrow.' end;
  end if;

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
  -- Nothing older than a day matters for any limit.
  delete from public.ai_usage where kind = p_kind and created_at < now() - interval '2 days';
  return null;
end;
$$;

revoke execute on function public.consume_ai_quota(uuid, text) from public, anon, authenticated;
grant execute on function public.consume_ai_quota(uuid, text) to service_role;
