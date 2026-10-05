-- Meal memory: also note "added" when a meal's ingredients merge into items
-- already on the list (add_recipe_to_list appends to items.recipe_ids instead
-- of inserting; see 20261005110000_pantry_and_tidy.sql), so a meal whose
-- groceries were all on the list already still counts as made.

create or replace function public.log_meal_merged()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.meal_events (list_id, recipe_id, meal_name, kind, user_id)
  select distinct n.list_id, r.id, r.name, 'added', auth.uid()
  from new_rows n
  join old_rows o on o.id = n.id
  cross join lateral unnest(n.recipe_ids) as rid
  join public.recipes r on r.id = rid
  where not (rid = any (o.recipe_ids))
    and not exists (
      select 1 from public.meal_events e
      where e.recipe_id = rid and e.kind = 'added' and e.created_at > now() - interval '12 hours'
    );
  return null;
end;
$$;

revoke execute on function public.log_meal_merged() from public, anon, authenticated;

create trigger items_log_meal_merged after update on public.items
  referencing old table as old_rows new table as new_rows
  for each statement execute function public.log_meal_merged();
