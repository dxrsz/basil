-- Explicit table privileges for the API roles.
--
-- Newer Supabase projects no longer grant table privileges to anon /
-- authenticated / service_role by default, so without this every request
-- fails with "permission denied" before RLS is even consulted. RLS (see the
-- init migration) still decides which rows a signed-in user can touch.
-- anon gets nothing: every part of Basil requires signing in.

grant usage on schema public to authenticated, service_role;

grant select, insert, update, delete on
  public.lists,
  public.list_members,
  public.list_invites,
  public.recipes,
  public.recipe_ingredients,
  public.items
to authenticated;

grant select, update on public.profiles to authenticated;

-- Edge functions use service_role (bypasses RLS) to write generated images.
grant all on all tables in schema public to service_role;

-- Keep it that way for tables added by future migrations.
alter default privileges in schema public grant all on tables to service_role;

-- RPCs are SECURITY DEFINER/INVOKER functions that check auth.uid(); make sure
-- anonymous callers can't even reach them.
revoke execute on function
  public.create_list(text, text),
  public.create_list_invite(uuid),
  public.join_list(text),
  public.add_recipe_to_list(uuid),
  public.remove_recipe_from_list(uuid),
  public.save_recipe(uuid, uuid, text, jsonb),
  public.clear_checked_items(uuid)
from public, anon;
