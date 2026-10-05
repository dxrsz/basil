-- Adding a meal to the list: an ingredient that's already checked off (in the
-- cart, or bought earlier) no longer blocks it. The new meal needs its own, so
-- it goes on the list as a fresh item. Unchecked matches still merge, with
-- quantities combined, and re-adding the same meal still doesn't double up.
-- "Got this already?" in the app is where someone says they have enough.

create or replace function public.add_recipe_to_list(p_recipe_id uuid, p_skip text[] default null)
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_list_id uuid;
  v_skip text[];
  v_keys text[] := '{}';
  v_names jsonb := '{}';
  v_qtys jsonb := '{}';
  v_key text;
  r record;
  v_item public.items%rowtype;
  v_n int := 0;
begin
  select list_id into v_list_id from public.recipes where id = p_recipe_id;
  if v_list_id is null then
    raise exception 'recipe not found' using errcode = 'P0002';
  end if;

  v_skip := array(select public.normalize_item_name(s) from unnest(coalesce(p_skip, '{}')) s);

  for r in
    select name, quantity from public.recipe_ingredients where recipe_id = p_recipe_id order by position
  loop
    v_key := public.normalize_item_name(r.name);
    continue when v_key = '' or v_key = any(v_skip);
    if v_key = any(v_keys) then
      v_qtys := jsonb_set(v_qtys, array[v_key],
        coalesce(to_jsonb(public.combine_quantities(v_qtys ->> v_key, r.quantity)), 'null'));
    else
      v_keys := array_append(v_keys, v_key);
      v_names := jsonb_set(v_names, array[v_key], to_jsonb(trim(r.name)));
      v_qtys := jsonb_set(v_qtys, array[v_key], coalesce(to_jsonb(nullif(trim(r.quantity), '')), 'null'));
    end if;
  end loop;

  foreach v_key in array v_keys loop
    continue when exists (
      select 1 from public.items
      where list_id = v_list_id and not checked and p_recipe_id = any(recipe_ids)
        and public.normalize_item_name(name) = v_key
    );

    select * into v_item from public.items
    where list_id = v_list_id and not checked and public.normalize_item_name(name) = v_key
    order by created_at
    limit 1
    for update;

    if found then
      update public.items
      set quantity = public.combine_quantities(quantity, v_qtys ->> v_key),
          recipe_ids = array_append(recipe_ids, p_recipe_id),
          recipe_id = coalesce(recipe_id, p_recipe_id)
      where id = v_item.id;
      v_n := v_n + 1;
    else
      insert into public.items (list_id, name, quantity, category, recipe_id, recipe_ids, manual)
      values (v_list_id, v_names ->> v_key, v_qtys ->> v_key, public.categorize_item(v_names ->> v_key),
              p_recipe_id, array[p_recipe_id], false);
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end;
$$;

grant execute on function public.add_recipe_to_list(uuid, text[]) to authenticated;
