-- Push notifications (FCM) for shared lists.
--
-- Events
--   shopping       someone starts shopping a list you're on   (client calls announce_shopping)
--   items_added    someone else added things to a list         (items trigger, batched)
--   member_joined  someone joined a list you're on             (list_members trigger)
--
-- Nothing is sent from SQL. Events are queued here and the `notify` edge
-- function claims and sends them:
--   * shopping / member_joined go into notification_outbox and kick the
--     function right away (pg_net);
--   * item adds are folded into one row per (list, person) in
--     item_add_batches, and only become due after 60 s without another add
--     (or 5 min after the first), so "Alex added 3 things" is one push, not 3.
--     A pg_cron job checks every 30 s and kicks the function when something
--     is due.
-- Events are only queued when some *other* member has a registered device,
-- so without Firebase set up nothing is ever queued.
--
-- The kick carries a random shared secret generated below and kept in
-- private.notify_config (not exposed through the API); the function checks it
-- with notify_secret_matches() using its service-role client.

create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

-- ------------------------------------------------------------ device tokens

create table public.device_tokens (
  token text primary key check (char_length(token) between 8 and 4096),
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  platform text not null check (platform in ('android', 'ios', 'web')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);

alter table public.device_tokens enable row level security;

create policy "device tokens: own read" on public.device_tokens
  for select to authenticated using (user_id = auth.uid());
create policy "device tokens: own insert" on public.device_tokens
  for insert to authenticated with check (user_id = auth.uid());
create policy "device tokens: own update" on public.device_tokens
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "device tokens: own delete" on public.device_tokens
  for delete to authenticated using (user_id = auth.uid());

-- A device's token can move between accounts (sign out, sign in as someone
-- else), which a plain upsert can't do under RLS; this claims it for the caller.
create or replace function public.register_device_token(p_token text, p_platform text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  insert into public.device_tokens (token, user_id, platform)
  values (p_token, auth.uid(), p_platform)
  on conflict (token) do update
    set user_id = auth.uid(), platform = excluded.platform, updated_at = now();
end;
$$;

-- --------------------------------------------------------------- settings

create table public.notification_settings (
  user_id uuid primary key default auth.uid() references auth.users (id) on delete cascade,
  enabled boolean not null default true,
  shopping boolean not null default true,
  items_added boolean not null default true,
  member_joined boolean not null default true,
  updated_at timestamptz not null default now()
);

alter table public.notification_settings enable row level security;

create policy "notification settings: own" on public.notification_settings
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create trigger notification_settings_touch before update on public.notification_settings
  for each row execute function public.touch_updated_at();

-- Lists the user has muted.
create table public.list_mutes (
  list_id uuid not null references public.lists (id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (list_id, user_id)
);

alter table public.list_mutes enable row level security;

create policy "list mutes: own read" on public.list_mutes
  for select to authenticated using (user_id = auth.uid());
create policy "list mutes: own insert" on public.list_mutes
  for insert to authenticated with check (user_id = auth.uid() and public.is_list_member(list_id));
create policy "list mutes: own delete" on public.list_mutes
  for delete to authenticated using (user_id = auth.uid());

-- ------------------------------------------------------------------ queue

-- Server-only tables: RLS on with no policies, so only service_role sees them.
create table public.notification_outbox (
  id bigint generated always as identity primary key,
  kind text not null check (kind in ('shopping', 'member_joined')),
  list_id uuid not null references public.lists (id) on delete cascade,
  actor_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

create table public.item_add_batches (
  list_id uuid not null references public.lists (id) on delete cascade,
  actor_id uuid not null references auth.users (id) on delete cascade,
  item_count int not null default 0,
  names text[] not null default '{}',
  first_at timestamptz not null default now(),
  last_at timestamptz not null default now(),
  primary key (list_id, actor_id)
);

-- When each person last announced they were shopping each list (dedupe).
create table public.shopping_announcements (
  list_id uuid not null references public.lists (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  announced_at timestamptz not null default now(),
  primary key (list_id, user_id)
);

alter table public.notification_outbox enable row level security;
alter table public.item_add_batches enable row level security;
alter table public.shopping_announcements enable row level security;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table private.notify_config (
  id int primary key default 1 check (id = 1),
  -- The deployed `notify` function. Change this for another project:
  --   update private.notify_config set function_url = 'https://<ref>.supabase.co/functions/v1/notify';
  function_url text,
  secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into private.notify_config (function_url)
values ('https://mrlumpodeelalofbdzpa.supabase.co/functions/v1/notify');

-- ---------------------------------------------------------------- helpers

-- Does anyone other than p_actor on this list have a device to notify?
create or replace function public.has_push_recipients(p_list_id uuid, p_actor uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.list_members m
    join public.device_tokens t on t.user_id = m.user_id
    where m.list_id = p_list_id and m.user_id <> p_actor
  );
$$;

-- Asks the notify function to send whatever is due. Fire-and-forget (pg_net
-- sends after commit).
create or replace function public.kick_notify()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select function_url, secret into v_url, v_secret from private.notify_config where id = 1;
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url := v_url,
    body := '{"type":"flush"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', v_secret),
    timeout_milliseconds := 10000
  );
end;
$$;

create or replace function public.notify_secret_matches(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select secret = p_secret from private.notify_config where id = 1), false);
$$;

-- ----------------------------------------------------------------- events

create or replace function public.queue_item_added()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := coalesce(new.created_by, auth.uid());
begin
  if v_actor is null or not public.has_push_recipients(new.list_id, v_actor) then
    return null;
  end if;
  insert into public.item_add_batches (list_id, actor_id, item_count, names)
  values (new.list_id, v_actor, 1, array[new.name])
  on conflict (list_id, actor_id) do update
    set item_count = item_add_batches.item_count + 1,
        names = case when cardinality(item_add_batches.names) < 5
                     then item_add_batches.names || excluded.names
                     else item_add_batches.names end,
        last_at = now();
  return null;
end;
$$;

create trigger items_queue_push after insert on public.items
  for each row execute function public.queue_item_added();

-- Added then removed before the batch went out (e.g. a typo): don't count it.
create or replace function public.unqueue_item_added()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.created_by is null then
    return null;
  end if;
  update public.item_add_batches
  set item_count = item_count - 1, names = array_remove(names, old.name)
  where list_id = old.list_id and actor_id = old.created_by and old.created_at >= first_at;
  delete from public.item_add_batches
  where list_id = old.list_id and actor_id = old.created_by and item_count <= 0;
  return null;
end;
$$;

create trigger items_unqueue_push after delete on public.items
  for each row execute function public.unqueue_item_added();

create or replace function public.queue_member_joined()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.role = 'owner' or not public.has_push_recipients(new.list_id, new.user_id) then
    return null;
  end if;
  insert into public.notification_outbox (kind, list_id, actor_id) values ('member_joined', new.list_id, new.user_id);
  perform public.kick_notify();
  return null;
end;
$$;

create trigger list_members_queue_push after insert on public.list_members
  for each row execute function public.queue_member_joined();

-- Called by the app when the user starts shopping a list (store mode).
-- At most one announcement per person per list every 30 minutes, so popping
-- in and out of store mode doesn't spam everyone. Returns whether this call
-- announced (false = deduped).
create or replace function public.announce_shopping(p_list_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_list_member(p_list_id) then
    raise exception 'not a member of this list' using errcode = '42501';
  end if;

  insert into public.shopping_announcements (list_id, user_id, announced_at)
  values (p_list_id, auth.uid(), now())
  on conflict (list_id, user_id) do update
    set announced_at = now()
    where shopping_announcements.announced_at < now() - interval '30 minutes';
  if not found then
    return false;
  end if;

  if public.has_push_recipients(p_list_id, auth.uid()) then
    insert into public.notification_outbox (kind, list_id, actor_id) values ('shopping', p_list_id, auth.uid());
    perform public.kick_notify();
  end if;
  return true;
end;
$$;

-- ------------------------------------------------------- for the function

-- Atomically takes everything that's due (each event is claimed exactly once,
-- even if two flushes overlap).
create or replace function public.claim_notifications()
returns table (kind text, list_id uuid, actor_id uuid, item_count int, names text[])
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
    with o as (delete from public.notification_outbox returning kind, list_id, actor_id)
    select o.kind, o.list_id, o.actor_id, 0, '{}'::text[] from o;
  return query
    with b as (
      delete from public.item_add_batches
      where last_at < now() - interval '60 seconds' or first_at < now() - interval '5 minutes'
      returning list_id, actor_id, item_count, names
    )
    select 'items_added'::text, b.list_id, b.actor_id, b.item_count, b.names from b where b.item_count > 0;
end;
$$;

-- Who to notify for an event: other members, with a device, who haven't
-- turned this kind off or muted the list.
create or replace function public.notification_recipients(p_list_id uuid, p_actor uuid, p_kind text)
returns table (user_id uuid, token text, platform text)
language sql
stable
security definer
set search_path = public
as $$
  select t.user_id, t.token, t.platform
  from public.list_members m
  join public.device_tokens t on t.user_id = m.user_id
  left join public.notification_settings s on s.user_id = m.user_id
  where m.list_id = p_list_id
    and m.user_id <> p_actor
    and coalesce(s.enabled, true)
    and case p_kind
          when 'shopping' then coalesce(s.shopping, true)
          when 'items_added' then coalesce(s.items_added, true)
          when 'member_joined' then coalesce(s.member_joined, true)
          else false
        end
    and not exists (select 1 from public.list_mutes x where x.list_id = p_list_id and x.user_id = m.user_id);
$$;

-- Every 30 s: if anything is due, kick the function (otherwise do nothing, so
-- an idle app costs no function invocations).
select cron.schedule(
  'notify-flush',
  '30 seconds',
  $cron$
    select public.kick_notify()
    where exists (select 1 from public.notification_outbox)
       or exists (
         select 1 from public.item_add_batches
         where last_at < now() - interval '60 seconds' or first_at < now() - interval '5 minutes'
       );
  $cron$
);

-- ----------------------------------------------------------------- grants

grant select, insert, update, delete on public.device_tokens, public.notification_settings, public.list_mutes
  to authenticated;
grant all on
  public.device_tokens,
  public.notification_settings,
  public.list_mutes,
  public.notification_outbox,
  public.item_add_batches,
  public.shopping_announcements
to service_role;

revoke execute on function
  public.register_device_token(text, text),
  public.announce_shopping(uuid),
  public.has_push_recipients(uuid, uuid),
  public.kick_notify(),
  public.notify_secret_matches(text),
  public.claim_notifications(),
  public.notification_recipients(uuid, uuid, text),
  public.queue_item_added(),
  public.unqueue_item_added(),
  public.queue_member_joined()
from public, anon, authenticated;

grant execute on function public.register_device_token(text, text), public.announce_shopping(uuid) to authenticated;
grant execute on function
  public.notify_secret_matches(text),
  public.claim_notifications(),
  public.notification_recipients(uuid, uuid, text)
to service_role;
