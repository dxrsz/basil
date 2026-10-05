-- claim_notifications() runs through PostgREST, where pg-safeupdate refuses a
-- DELETE without a WHERE clause ("DELETE requires a WHERE clause"). Same
-- function, with an explicit (always-true) condition on the outbox delete.

create or replace function public.claim_notifications()
returns table (kind text, list_id uuid, actor_id uuid, item_count int, names text[])
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  return query
    with o as (delete from public.notification_outbox where id is not null returning kind, list_id, actor_id)
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

revoke execute on function public.claim_notifications() from public, anon, authenticated;
grant execute on function public.claim_notifications() to service_role;
