-- Pantry staples ("Got this already?") and smart list cleanup.
--
-- 1. Items merge instead of duplicating. normalize_item_name() makes
--    "Avocados" and "avocado" the same item, and combine_quantities() adds
--    up compatible amounts ("2 cups" + "1 cup" → "3 cups", otherwise
--    "1 bunch + 2"). Both are mirrored in lib/util/item_merge.dart; shared test
--    vectors live in test/fixtures/item_merge_cases.json.
-- 2. An item can come from several meals: items.recipe_ids lists them all and
--    items.recipe_id stays the primary one (kept for older clients and the FK).
--    items.manual records whether someone also added it by hand, so taking a
--    meal off the list never deletes something a person typed in.
-- 3. pantry_staples remembers, per list, what the household said it already
--    has, so adding a meal can leave those off the list.

-- --------------------------------------------------------- name matching

create or replace function public.normalize_item_name(p_name text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  w text;
  v_out text[] := '{}';
begin
  foreach w in array regexp_split_to_array(trim(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', ' ', 'g')), ' ')
  loop
    continue when w = '';
    if length(w) > 3 then
      if w ~ 'ies$' then
        w := left(w, -3) || 'y';
      elsif w ~ 'oes$' then
        w := left(w, -2);
      elsif w ~ '(ch|sh|x|ss)es$' then
        w := left(w, -2);
      elsif w ~ '(ss|us|is)$' then
        null;
      elsif w ~ 's$' then
        w := left(w, -1);
      end if;
    end if;
    v_out := array_append(v_out, w);
  end loop;
  return array_to_string(v_out, ' ');
end;
$$;

-- ------------------------------------------------------------- quantities

create or replace function public.qty_unit_key(p_unit text)
returns text
language sql
immutable
set search_path = public
as $$
  select case u
    when 'cup' then 'cup' when 'cups' then 'cup'
    when 'tablespoon' then 'tbsp' when 'tablespoons' then 'tbsp' when 'tbsp' then 'tbsp'
    when 'tbsps' then 'tbsp' when 'tbs' then 'tbsp'
    when 'teaspoon' then 'tsp' when 'teaspoons' then 'tsp' when 'tsp' then 'tsp' when 'tsps' then 'tsp'
    when 'pound' then 'lb' when 'pounds' then 'lb' when 'lb' then 'lb' when 'lbs' then 'lb'
    when 'ounce' then 'oz' when 'ounces' then 'oz' when 'oz' then 'oz'
    when 'gram' then 'g' when 'grams' then 'g' when 'g' then 'g'
    when 'kilogram' then 'kg' when 'kilograms' then 'kg' when 'kg' then 'kg' when 'kgs' then 'kg'
    when 'ml' then 'ml' when 'milliliter' then 'ml' when 'milliliters' then 'ml'
    when 'l' then 'l' when 'liter' then 'l' when 'liters' then 'l' when 'litre' then 'l' when 'litres' then 'l'
    when 'x' then '' when 'ct' then '' when 'count' then ''
    else public.normalize_item_name(u)
  end
  from (select regexp_replace(trim(p_unit), '\.$', '') as u) s;
$$;

create or replace function public.qty_unit_plural(p_unit text)
returns text
language sql
immutable
as $$
  select case
    when p_unit in ('', 'tbsp', 'tsp', 'lb', 'oz', 'g', 'kg', 'ml', 'l', 'dozen', 'large', 'medium', 'small', 'whole')
      or p_unit !~ '[a-z]$' then p_unit
    when p_unit ~ '(ch|sh|x|s)$' then p_unit || 'es'
    when p_unit ~ '[^aeiou]y$' then left(p_unit, -1) || 'ies'
    else p_unit || 's'
  end;
$$;

-- One "+"-separated piece of a quantity. unit is null for opaque text like
-- "to taste"; '' means a plain count.
create or replace function public.qty_parse_term(p_term text, out unit text, out val numeric, out txt text)
language plpgsql
immutable
set search_path = public
as $$
declare
  t text;
  w text;
  n numeric;
  m text[];
  mm text[];
  num text;
begin
  txt := trim(p_term);
  t := regexp_replace(lower(txt), '\s+', ' ', 'g');
  w := substring(t from '^([a-z]+)(?: |$)');
  if w is not null then
    n := case w
      when 'a' then 1 when 'an' then 1 when 'one' then 1 when 'two' then 2 when 'three' then 3
      when 'four' then 4 when 'five' then 5 when 'six' then 6 when 'seven' then 7 when 'eight' then 8
      when 'nine' then 9 when 'ten' then 10 when 'twelve' then 12
    end;
    if n is not null then
      t := n::text || substr(t, length(w) + 1);
    end if;
  end if;

  m := regexp_match(t, '^(\d+\s+\d+/\d+|\d+/\d+|\d*\.\d+|\d+\s*[½¼¾⅓⅔]?|[½¼¾⅓⅔])\s*([a-z].*)?$');
  if m is null then
    return;
  end if;
  num := trim(m[1]);
  if num ~ '^\d+\s+\d+/\d+$' then
    mm := regexp_match(num, '^(\d+)\s+(\d+)/(\d+)$');
    if mm[3]::numeric = 0 then return; end if;
    n := mm[1]::numeric + mm[2]::numeric / mm[3]::numeric;
  elsif num ~ '^\d+/\d+$' then
    mm := regexp_match(num, '^(\d+)/(\d+)$');
    if mm[2]::numeric = 0 then return; end if;
    n := mm[1]::numeric / mm[2]::numeric;
  elsif num ~ '[½¼¾⅓⅔]$' then
    n := coalesce(nullif(substring(num from '^(\d*)'), '')::numeric, 0)
      + case right(num, 1)
          when '½' then 0.5 when '¼' then 0.25 when '¾' then 0.75
          when '⅓' then 1::numeric / 3 when '⅔' then 2::numeric / 3
        end;
  else
    n := num::numeric;
  end if;
  val := n;
  unit := public.qty_unit_key(coalesce(m[2], ''));
end;
$$;

create or replace function public.qty_format_amount(v numeric)
returns text
language plpgsql
immutable
as $$
declare
  whole numeric;
  frac numeric;
  glyphs text[] := array['½', '¼', '¾', '⅓', '⅔'];
  fracs numeric[] := array[0.5, 0.25, 0.75, 1::numeric / 3, 2::numeric / 3];
begin
  if abs(v - round(v)) < 0.005 then
    return round(v)::text;
  end if;
  whole := floor(v);
  frac := v - whole;
  for i in 1..5 loop
    if abs(frac - fracs[i]) < 0.01 then
      return case when whole = 0 then glyphs[i] else whole::text || glyphs[i] end;
    end if;
  end loop;
  return rtrim(rtrim(to_char(round(v, 2), 'FM999999990.00'), '0'), '.');
end;
$$;

-- Combines two quantities for the same item: amounts in the same unit add up,
-- anything else is kept side by side. A missing quantity contributes nothing.
create or replace function public.combine_quantities(p_existing text, p_added text)
returns text
language plpgsql
immutable
set search_path = public
as $$
declare
  a text := trim(coalesce(p_existing, ''));
  b text := trim(coalesce(p_added, ''));
  units text[] := '{}';
  vals numeric[] := '{}';
  texts text[] := '{}';
  piece text;
  r record;
  hit int;
  v_out text[] := '{}';
  amount text;
begin
  if b = '' then return nullif(a, ''); end if;
  if a = '' then return b; end if;

  foreach piece in array regexp_split_to_array(a, '\+') loop
    continue when trim(piece) = '';
    r := public.qty_parse_term(piece);
    units := array_append(units, r.unit);
    vals := array_append(vals, r.val);
    texts := array_append(texts, r.txt);
  end loop;

  foreach piece in array regexp_split_to_array(b, '\+') loop
    continue when trim(piece) = '';
    r := public.qty_parse_term(piece);
    hit := null;
    for i in 1..coalesce(array_length(units, 1), 0) loop
      if r.unit is null then
        if units[i] is null and lower(texts[i]) = lower(r.txt) then hit := i; exit; end if;
      elsif units[i] = r.unit then
        hit := i; exit;
      end if;
    end loop;
    if hit is null then
      units := array_append(units, r.unit);
      vals := array_append(vals, r.val);
      texts := array_append(texts, r.txt);
    elsif r.unit is not null then
      vals[hit] := vals[hit] + r.val;
    end if;
  end loop;

  for i in 1..coalesce(array_length(units, 1), 0) loop
    if units[i] is null then
      v_out := array_append(v_out, texts[i]);
    else
      amount := public.qty_format_amount(vals[i]);
      v_out := array_append(v_out, case
        when units[i] = '' then amount
        else amount || ' ' || case when vals[i] > 1 then public.qty_unit_plural(units[i]) else units[i] end
      end);
    end if;
  end loop;
  return array_to_string(v_out, ' + ');
end;
$$;

-- ------------------------------------------------------- items ← meals

alter table public.items
  add column recipe_ids uuid[] not null default '{}',
  add column manual boolean;

update public.items set recipe_ids = array[recipe_id], manual = false where recipe_id is not null;
update public.items set manual = true where manual is null;
alter table public.items alter column manual set not null;

create index items_list_name_key_idx on public.items (list_id, public.normalize_item_name(name)) where not checked;

-- Keeps recipe_id ∈ recipe_ids for writers that only know about recipe_id
-- (older app versions, Undo), and fills in `manual` when the writer didn't.
create or replace function public.items_sync_recipe_ids()
returns trigger
language plpgsql
as $$
begin
  if new.recipe_id is not null and not (new.recipe_id = any(new.recipe_ids)) then
    new.recipe_ids := array_append(new.recipe_ids, new.recipe_id);
  end if;
  if new.manual is null then
    new.manual := new.recipe_id is null;
  end if;
  return new;
end;
$$;

create trigger items_sync_recipe_ids before insert or update on public.items
  for each row execute function public.items_sync_recipe_ids();

-- Add one item, merging into an unchecked item with the same name instead of
-- duplicating it. Returns {id, merged, name, quantity} of the resulting row.
create or replace function public.add_item(
  p_list_id uuid,
  p_name text,
  p_quantity text default null,
  p_category text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_name text := left(trim(coalesce(p_name, '')), 120);
  v_qty text := nullif(trim(coalesce(p_quantity, '')), '');
  v_item public.items%rowtype;
begin
  if not public.is_list_member(p_list_id) then
    raise exception 'not a member of this list' using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'item name is required' using errcode = '22023';
  end if;

  select * into v_item from public.items
  where list_id = p_list_id and not checked
    and public.normalize_item_name(name) = public.normalize_item_name(v_name)
  order by created_at
  limit 1
  for update;

  if found then
    update public.items
    set quantity = public.combine_quantities(quantity, v_qty), manual = true
    where id = v_item.id
    returning * into v_item;
    return jsonb_build_object('id', v_item.id, 'merged', true, 'name', v_item.name, 'quantity', v_item.quantity);
  end if;

  insert into public.items (list_id, name, quantity, category, manual)
  values (p_list_id, v_name, v_qty, coalesce(nullif(p_category, ''), public.categorize_item(v_name)), true)
  returning * into v_item;
  return jsonb_build_object('id', v_item.id, 'merged', false, 'name', v_item.name, 'quantity', v_item.quantity);
end;
$$;

-- Put a meal's ingredients on its list.
--
-- p_skip: ingredient names the household already has ("Got it"); left off.
-- For each remaining ingredient (duplicate lines within the meal combined):
--   * already on the list from this meal, still to get → skipped (re-saving a
--     meal doesn't double it);
--   * on the list, still to get → merged: quantities combined, meal recorded;
--   * only in the cart → skipped, so re-adding mid-shop doesn't re-add what
--     you just bought;
--   * otherwise → added, tagged with the meal.
-- Returns the number of items added or merged.
drop function if exists public.add_recipe_to_list(uuid);
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
    elsif not exists (
      select 1 from public.items
      where list_id = v_list_id and checked and public.normalize_item_name(name) = v_key
    ) then
      insert into public.items (list_id, name, quantity, category, recipe_id, recipe_ids, manual)
      values (v_list_id, v_names ->> v_key, v_qtys ->> v_key, public.categorize_item(v_names ->> v_key),
              p_recipe_id, array[p_recipe_id], false);
      v_n := v_n + 1;
    end if;
  end loop;

  return v_n;
end;
$$;

-- Take a meal's still-unchecked items off its list. Items that only this meal
-- put there are removed; items shared with another meal (or also typed in by
-- hand) stay, just no longer tagged with this meal.
create or replace function public.remove_recipe_from_list(p_recipe_id uuid)
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_removed int;
begin
  delete from public.items
  where not checked and not manual and p_recipe_id = any(recipe_ids)
    and not exists (
      select 1 from unnest(recipe_ids) other
      where other <> p_recipe_id and exists (select 1 from public.recipes where id = other)
    );
  get diagnostics v_removed = row_count;

  update public.items i
  set recipe_ids = array_remove(i.recipe_ids, p_recipe_id),
      recipe_id = case when i.recipe_id = p_recipe_id then (
        select other from unnest(array_remove(i.recipe_ids, p_recipe_id)) with ordinality as u(other, ord)
        where exists (select 1 from public.recipes where id = other)
        order by ord limit 1
      ) else i.recipe_id end
  where not i.checked and p_recipe_id = any(i.recipe_ids);

  return v_removed;
end;
$$;

-- --------------------------------------------------------------- tidy up

-- Apply reviewed "Tidy up" changes atomically.
-- p_changes: [{"keep_id": uuid, "remove_ids": [uuid...], "name": text?, "quantity": text|null?}]
-- The kept item takes the new name/quantity (when given) and inherits the
-- meals of the items merged into it, which are deleted. A change is skipped
-- if any of its items has since been checked off or removed.
-- Returns the number of changes applied.
create or replace function public.apply_tidy(p_list_id uuid, p_changes jsonb)
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  c jsonb;
  v_keep public.items%rowtype;
  v_remove uuid[];
  v_found int;
  v_ids uuid[];
  v_manual boolean;
  v_primary uuid;
  v_name text;
  rid uuid;
  other record;
  v_n int := 0;
begin
  if not public.is_list_member(p_list_id) then
    raise exception 'not a member of this list' using errcode = '42501';
  end if;
  if jsonb_typeof(p_changes) <> 'array' then
    raise exception 'changes must be an array' using errcode = '22023';
  end if;

  for c in select * from jsonb_array_elements(p_changes) loop
    select * into v_keep from public.items
    where id = (c ->> 'keep_id')::uuid and list_id = p_list_id and not checked
    for update;
    continue when not found;

    v_remove := array(
      select distinct x::uuid from jsonb_array_elements_text(coalesce(c -> 'remove_ids', '[]')) x
      where x::uuid <> v_keep.id
    );
    select count(*) into v_found from (
      select 1 from public.items
      where id = any(v_remove) and list_id = p_list_id and not checked
      for update
    ) s;
    continue when v_found <> coalesce(array_length(v_remove, 1), 0);

    v_ids := v_keep.recipe_ids;
    v_manual := v_keep.manual;
    v_primary := v_keep.recipe_id;
    for other in select recipe_id, recipe_ids, manual from public.items where id = any(v_remove) order by created_at loop
      foreach rid in array other.recipe_ids loop
        if not rid = any(v_ids) then v_ids := array_append(v_ids, rid); end if;
      end loop;
      v_manual := v_manual or other.manual;
      v_primary := coalesce(v_primary, other.recipe_id);
    end loop;

    v_name := left(nullif(trim(coalesce(c ->> 'name', '')), ''), 120);
    update public.items
    set name = coalesce(v_name, name),
        category = public.categorize_item(coalesce(v_name, name)),
        quantity = case when c ? 'quantity' then nullif(trim(coalesce(c ->> 'quantity', '')), '') else quantity end,
        recipe_ids = v_ids,
        recipe_id = v_primary,
        manual = v_manual
    where id = v_keep.id;

    delete from public.items where id = any(v_remove);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ------------------------------------------------------------- pantry

create table public.pantry_staples (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  name_key text generated always as (public.normalize_item_name(name)) stored check (name_key <> ''),
  -- Pinned "always have" staples never expire; other answers are trusted for
  -- 30 days (see lib/features/pantry/pantry_logic.dart).
  always boolean not null default false,
  confirmed_at timestamptz not null default now(),
  confirmed_by uuid default auth.uid() references auth.users (id) on delete set null,
  unique (list_id, name_key)
);

alter table public.pantry_staples enable row level security;

create policy "pantry: members all" on public.pantry_staples
  for all to authenticated
  using (public.is_list_member(list_id))
  with check (public.is_list_member(list_id));

grant select, insert, update, delete on public.pantry_staples to authenticated;
grant all on public.pantry_staples to service_role;

alter publication supabase_realtime add table public.pantry_staples;

-- Record answers from the "Got this already?" review: p_have are things the
-- household has (remembered, or re-confirmed), p_forget are things it said it
-- needs after all (forgotten, unless pinned as "always have").
create or replace function public.remember_pantry(p_list_id uuid, p_have text[], p_forget text[] default null)
returns void
language plpgsql
security invoker
set search_path = public
as $$
begin
  if not public.is_list_member(p_list_id) then
    raise exception 'not a member of this list' using errcode = '42501';
  end if;

  insert into public.pantry_staples (list_id, name)
  select distinct on (public.normalize_item_name(n)) p_list_id, left(trim(n), 120)
  from unnest(coalesce(p_have, '{}')) n
  where public.normalize_item_name(n) <> ''
  on conflict (list_id, name_key) do update set confirmed_at = now(), confirmed_by = auth.uid();

  delete from public.pantry_staples
  where list_id = p_list_id and not always
    and name_key = any(array(select public.normalize_item_name(n) from unnest(coalesce(p_forget, '{}')) n));
end;
$$;

-- --------------------------------------------------------------- grants

revoke execute on function
  public.add_item(uuid, text, text, text),
  public.add_recipe_to_list(uuid, text[]),
  public.apply_tidy(uuid, jsonb),
  public.remember_pantry(uuid, text[], text[])
from public, anon;

grant execute on function
  public.add_item(uuid, text, text, text),
  public.add_recipe_to_list(uuid, text[]),
  public.apply_tidy(uuid, jsonb),
  public.remember_pantry(uuid, text[], text[]),
  public.normalize_item_name(text),
  public.combine_quantities(text, text)
to authenticated;
