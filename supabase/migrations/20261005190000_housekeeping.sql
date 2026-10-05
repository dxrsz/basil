-- Nightly housekeeping, so nothing grows without bound and the database
-- needs no hand maintenance (autovacuum, backups and patching are already
-- handled by Postgres / Supabase).
--
-- public.housekeeping(), run by pg_cron at 03:17 UTC:
--   - cron.job_run_details older than 7 days (notify-flush alone logs ~2,900
--     runs a day and pg_cron never prunes them)
--   - meal_events older than a year (the planner reads the last 120 days)
--   - invites that expired over 30 days ago
--   - shopping_announcements older than a day (only the last 30 min matter)
--   - names stuck in the category queue for a week
--   - meal photos no meal points to any more (deleted meals): queued here,
--     then deleted through the storage API by the housekeeping edge function
--     (storage files can't be removed with SQL alone)

create schema if not exists private;

create table private.image_deletions (
  path text primary key,
  queued_at timestamptz not null default now()
);

create table private.housekeeping_config (
  id int primary key default 1 check (id = 1),
  -- The deployed housekeeping function. For another project:
  --   update private.housekeeping_config set function_url = 'https://<ref>.supabase.co/functions/v1/housekeeping';
  function_url text,
  secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into private.housekeeping_config (function_url)
values ('https://mrlumpodeelalofbdzpa.supabase.co/functions/v1/housekeeping');

create or replace function public.housekeeping()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v jsonb := '{}';
  n int;
  v_url text;
  v_secret text;
begin
  delete from cron.job_run_details where end_time < now() - interval '7 days';
  get diagnostics n = row_count; v := v || jsonb_build_object('cron_log', n);

  delete from public.meal_events where created_at < now() - interval '1 year';
  get diagnostics n = row_count; v := v || jsonb_build_object('meal_events', n);

  delete from public.list_invites where expires_at < now() - interval '30 days';
  get diagnostics n = row_count; v := v || jsonb_build_object('invites', n);

  delete from public.shopping_announcements where announced_at < now() - interval '1 day';
  get diagnostics n = row_count; v := v || jsonb_build_object('announcements', n);

  delete from private.category_queue where queued_at < now() - interval '7 days';
  get diagnostics n = row_count; v := v || jsonb_build_object('stale_category_queue', n);

  -- Photos no meal uses. A day's grace so a photo mid-generation (uploaded,
  -- row not updated yet) is never touched.
  insert into private.image_deletions (path)
  select o.name from storage.objects o
  where o.bucket_id = 'recipe-images'
    and o.created_at < now() - interval '1 day'
    and not exists (
      select 1 from public.recipes r
      where r.image_url like '%/object/public/recipe-images/' || o.name
    )
  on conflict do nothing;
  get diagnostics n = row_count; v := v || jsonb_build_object('orphan_images_queued', n);

  if exists (select 1 from private.image_deletions) then
    select function_url, secret into v_url, v_secret from private.housekeeping_config where id = 1;
    if v_url is not null then
      perform net.http_post(
        url := v_url,
        body := '{"type":"images"}'::jsonb,
        headers := jsonb_build_object('Content-Type', 'application/json', 'x-housekeeping-secret', v_secret),
        timeout_milliseconds := 10000
      );
    end if;
  end if;
  return v;
end;
$$;

-- For the housekeeping edge function (service role).
create or replace function public.housekeeping_secret_matches(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select secret = p_secret from private.housekeeping_config where id = 1), false);
$$;

create or replace function public.claim_image_deletions(p_limit int default 500)
returns setof text
language sql
security definer
set search_path = public
as $$
  delete from private.image_deletions d
  where d.path in (select path from private.image_deletions order by queued_at limit p_limit)
  returning d.path;
$$;

revoke execute on function public.housekeeping(), public.housekeeping_secret_matches(text),
  public.claim_image_deletions(int) from public, anon, authenticated;
grant execute on function public.housekeeping_secret_matches(text), public.claim_image_deletions(int)
  to service_role;

select cron.schedule('housekeeping', '17 3 * * *', $$select public.housekeeping()$$);
