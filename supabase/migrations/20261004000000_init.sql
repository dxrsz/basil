-- Basil: shared shopping lists + AI-assisted meal "recipes".
--
-- Model
--   lists ─┬─ list_members (who can see/edit a list)
--          ├─ list_invites (short codes for joining a list)
--          ├─ items        (the shopping list itself; optionally tagged with a recipe)
--          └─ recipes ── recipe_ingredients
--
-- A recipe is just a meal name plus the ingredients the user associates with it.
-- "Adding a recipe to the list" copies its ingredients into `items` tagged with
-- recipe_id, so clearing bought items never destroys the recipe itself.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------- profiles

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text not null default '',
  avatar_url text,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, avatar_url)
  values (
    new.id,
    coalesce(
      new.raw_user_meta_data ->> 'full_name',
      new.raw_user_meta_data ->> 'name',
      split_part(new.email, '@', 1),
      'Cook'
    ),
    coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture')
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ------------------------------------------------------------------- lists

create table public.lists (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 80),
  emoji text not null default '🛒',
  owner_id uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.list_members (
  list_id uuid not null references public.lists (id) on delete cascade,
  -- references profiles (which cascades from auth.users) so PostgREST can embed it
  user_id uuid not null references public.profiles (id) on delete cascade,
  role text not null default 'editor' check (role in ('owner', 'editor')),
  joined_at timestamptz not null default now(),
  primary key (list_id, user_id)
);
create index list_members_user_idx on public.list_members (user_id);

create table public.list_invites (
  code text primary key,
  list_id uuid not null references public.lists (id) on delete cascade,
  created_by uuid not null default auth.uid() references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days'
);
create index list_invites_list_idx on public.list_invites (list_id);

-- ----------------------------------------------------------------- recipes

create table public.recipes (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  image_url text,
  -- idle | generating | ready | failed
  image_status text not null default 'idle'
    check (image_status in ('idle', 'generating', 'ready', 'failed')),
  -- Hash of (name + sorted ingredients) the current image was generated from,
  -- so the edge function can skip regenerating an image that is still accurate.
  image_signature text,
  created_by uuid not null default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index recipes_list_idx on public.recipes (list_id);

create table public.recipe_ingredients (
  id uuid primary key default gen_random_uuid(),
  recipe_id uuid not null references public.recipes (id) on delete cascade,
  -- denormalised so realtime streams can filter on it and RLS stays cheap
  list_id uuid not null references public.lists (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  quantity text,
  position int not null default 0,
  created_at timestamptz not null default now()
);
create index recipe_ingredients_recipe_idx on public.recipe_ingredients (recipe_id);
create index recipe_ingredients_list_idx on public.recipe_ingredients (list_id);

-- ------------------------------------------------------------------- items

create table public.items (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists (id) on delete cascade,
  name text not null check (char_length(name) between 1 and 120),
  quantity text,
  category text not null default 'Other',
  checked boolean not null default false,
  checked_by uuid references auth.users (id) on delete set null,
  checked_at timestamptz,
  recipe_id uuid references public.recipes (id) on delete set null,
  created_by uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index items_list_idx on public.items (list_id);
create index items_recipe_idx on public.items (recipe_id);

-- ------------------------------------------------------------- triggers

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger lists_touch before update on public.lists
  for each row execute function public.touch_updated_at();
create trigger recipes_touch before update on public.recipes
  for each row execute function public.touch_updated_at();
create trigger items_touch before update on public.items
  for each row execute function public.touch_updated_at();

-- Stamp who checked an item off, server-side, so clients can't spoof it.
create or replace function public.stamp_item_checked()
returns trigger language plpgsql as $$
begin
  if new.checked is distinct from old.checked then
    if new.checked then
      new.checked_by = auth.uid();
      new.checked_at = now();
    else
      new.checked_by = null;
      new.checked_at = null;
    end if;
  end if;
  return new;
end;
$$;

create trigger items_stamp_checked before update on public.items
  for each row execute function public.stamp_item_checked();

-- The creator of a list automatically becomes its owner-member.
create or replace function public.add_list_owner()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.list_members (list_id, user_id, role)
  values (new.id, new.owner_id, 'owner');
  return new;
end;
$$;

create trigger lists_add_owner after insert on public.lists
  for each row execute function public.add_list_owner();

-- ---------------------------------------------------------------- helpers

-- security definer so policies on list_members can call it without recursing.
create or replace function public.is_list_member(p_list_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.list_members
    where list_id = p_list_id and user_id = auth.uid()
  );
$$;

create or replace function public.shares_a_list_with(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.list_members a
    join public.list_members b on a.list_id = b.list_id
    where a.user_id = auth.uid() and b.user_id = p_user_id
  );
$$;

-- -------------------------------------------------------------------- RLS

alter table public.profiles enable row level security;
alter table public.lists enable row level security;
alter table public.list_members enable row level security;
alter table public.list_invites enable row level security;
alter table public.recipes enable row level security;
alter table public.recipe_ingredients enable row level security;
alter table public.items enable row level security;

create policy "profiles: read self and collaborators" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.shares_a_list_with(id));
create policy "profiles: update self" on public.profiles
  for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "lists: members read" on public.lists
  for select to authenticated using (public.is_list_member(id));
create policy "lists: anyone creates own" on public.lists
  for insert to authenticated with check (owner_id = auth.uid());
create policy "lists: members update" on public.lists
  for update to authenticated using (public.is_list_member(id));
create policy "lists: owner deletes" on public.lists
  for delete to authenticated using (owner_id = auth.uid());

create policy "members: members read" on public.list_members
  for select to authenticated using (public.is_list_member(list_id));
-- Leaving a list, or the owner removing someone. Joining goes through join_list().
create policy "members: leave or owner removes" on public.list_members
  for delete to authenticated using (
    user_id = auth.uid()
    or exists (select 1 from public.lists l where l.id = list_id and l.owner_id = auth.uid())
  );

create policy "invites: members read" on public.list_invites
  for select to authenticated using (public.is_list_member(list_id));
create policy "invites: members create" on public.list_invites
  for insert to authenticated with check (public.is_list_member(list_id));
create policy "invites: members delete" on public.list_invites
  for delete to authenticated using (public.is_list_member(list_id));

create policy "recipes: members all" on public.recipes
  for all to authenticated
  using (public.is_list_member(list_id))
  with check (public.is_list_member(list_id));

create policy "ingredients: members all" on public.recipe_ingredients
  for all to authenticated
  using (public.is_list_member(list_id))
  with check (
    public.is_list_member(list_id)
    and exists (select 1 from public.recipes r where r.id = recipe_id and r.list_id = list_id)
  );

create policy "items: members all" on public.items
  for all to authenticated
  using (public.is_list_member(list_id))
  with check (public.is_list_member(list_id));

-- -------------------------------------------------------------------- RPCs

-- Create a list (and owner membership). An RPC rather than a plain insert so
-- the caller can read the row back immediately; INSERT ... RETURNING would be
-- checked against the select policy before the owner-member trigger has run.
create or replace function public.create_list(p_name text, p_emoji text default '🛒')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;
  insert into public.lists (name, emoji, owner_id)
  values (trim(p_name), coalesce(nullif(p_emoji, ''), '🛒'), auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;

-- Create (or reuse) a short, human-friendly invite code for a list.
create or replace function public.create_list_invite(p_list_id uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_code text;
  -- no 0/O/1/I to keep codes easy to read aloud
  v_alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if not public.is_list_member(p_list_id) then
    raise exception 'not a member of this list' using errcode = '42501';
  end if;

  select code into v_code from public.list_invites
  where list_id = p_list_id and expires_at > now() + interval '1 day'
  order by expires_at desc limit 1;
  if v_code is not null then
    return v_code;
  end if;

  loop
    v_code := '';
    for i in 1..6 loop
      v_code := v_code || substr(v_alphabet, 1 + floor(random() * length(v_alphabet))::int, 1);
    end loop;
    begin
      insert into public.list_invites (code, list_id, created_by)
      values (v_code, p_list_id, auth.uid());
      return v_code;
    exception when unique_violation then
      -- collision; try another code
    end;
  end loop;
end;
$$;

-- Join a list by invite code. Returns the list id.
create or replace function public.join_list(p_code text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_list_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not signed in' using errcode = '42501';
  end if;

  select list_id into v_list_id from public.list_invites
  where code = upper(trim(p_code)) and expires_at > now();
  if v_list_id is null then
    raise exception 'That invite code is invalid or has expired' using errcode = 'P0002';
  end if;

  insert into public.list_members (list_id, user_id, role)
  values (v_list_id, auth.uid(), 'editor')
  on conflict do nothing;

  return v_list_id;
end;
$$;

-- Copy a recipe's ingredients onto its list as unchecked items. Ingredients
-- already on the list by name (still to get, or already in the cart) are
-- skipped, so re-saving a meal mid-shop doesn't re-add what you just bought.
-- Returns the number of items added.
create or replace function public.add_recipe_to_list(p_recipe_id uuid)
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_list_id uuid;
  v_added int;
begin
  select list_id into v_list_id from public.recipes where id = p_recipe_id;
  if v_list_id is null then
    raise exception 'recipe not found' using errcode = 'P0002';
  end if;

  insert into public.items (list_id, name, quantity, category, recipe_id)
  select v_list_id, ri.name, ri.quantity, public.categorize_item(ri.name), p_recipe_id
  from public.recipe_ingredients ri
  where ri.recipe_id = p_recipe_id
    and not exists (
      select 1 from public.items i
      where i.list_id = v_list_id
        and lower(trim(i.name)) = lower(trim(ri.name))
    )
  order by ri.position;

  get diagnostics v_added = row_count;
  return v_added;
end;
$$;

-- Remove a recipe's still-unchecked items from its list.
create or replace function public.remove_recipe_from_list(p_recipe_id uuid)
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_removed int;
begin
  delete from public.items where recipe_id = p_recipe_id and not checked;
  get diagnostics v_removed = row_count;
  return v_removed;
end;
$$;

-- Replace a recipe's name + ingredient list in one transaction.
-- p_ingredients: [{"name": "...", "quantity": "..."}, ...]
create or replace function public.save_recipe(
  p_list_id uuid,
  p_recipe_id uuid,
  p_name text,
  p_ingredients jsonb
)
returns uuid
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid := p_recipe_id;
begin
  if v_id is null then
    insert into public.recipes (list_id, name) values (p_list_id, trim(p_name))
    returning id into v_id;
  else
    update public.recipes set name = trim(p_name) where id = v_id and list_id = p_list_id;
    if not found then
      raise exception 'recipe not found' using errcode = 'P0002';
    end if;
    delete from public.recipe_ingredients where recipe_id = v_id;
  end if;

  insert into public.recipe_ingredients (recipe_id, list_id, name, quantity, position)
  select v_id, p_list_id, trim(e ->> 'name'), nullif(trim(e ->> 'quantity'), ''), (ord - 1)::int
  from jsonb_array_elements(p_ingredients) with ordinality as t(e, ord)
  where coalesce(trim(e ->> 'name'), '') <> '';

  return v_id;
end;
$$;

-- Clear bought items from a list.
create or replace function public.clear_checked_items(p_list_id uuid)
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_removed int;
begin
  delete from public.items where list_id = p_list_id and checked;
  get diagnostics v_removed = row_count;
  return v_removed;
end;
$$;

-- Cheap keyword-based aisle grouping, shared by the client (for typed items)
-- and add_recipe_to_list. The client has a mirror of this in item_categories.dart.
create or replace function public.categorize_item(p_name text)
returns text
language sql
immutable
as $$
  select case
    when n ~ '(chicken|beef|pork|steak|bacon|sausage|turkey|lamb|ham|salami|prosciutto|ground meat|mince)' then 'Meat'
    when n ~ '(salmon|tuna|shrimp|prawn|cod|tilapia|fish|crab|lobster|scallop|mussel|clam)' then 'Seafood'
    when n ~ '(milk|cheese|yogurt|yoghurt|butter|cream|egg|feta|parmesan|mozzarella|cheddar|ricotta)' then 'Dairy & Eggs'
    when n ~ '(bread|bun|bagel|tortilla|pita|naan|baguette|croissant|roll)' then 'Bakery'
    when n ~ '(frozen|ice cream)' then 'Frozen'
    when n ~ '(apple|banana|lemon|lime|orange|berry|berries|avocado|tomato|onion|garlic|potato|lettuce|spinach|kale|carrot|pepper|cucumber|broccoli|cilantro|parsley|basil|mint|ginger|scallion|celery|mushroom|zucchini|corn|cabbage|edamame|mango|grape|herb|jalape)' then 'Produce'
    when n ~ '(rice|pasta|noodle|quinoa|oat|flour|sugar|bean|lentil|chickpea|can |canned|broth|stock|sauce|oil|vinegar|salt|spice|cumin|paprika|cinnamon|oregano|soy|honey|syrup|cereal|nut|seed|salsa|mayo|mustard|ketchup|sriracha|tahini|cracker|chip)' then 'Pantry'
    when n ~ '(water|juice|soda|coffee|tea|wine|beer|kombucha|sparkling)' then 'Drinks'
    when n ~ '(paper|towel|soap|detergent|foil|wrap|bag|sponge|trash|tissue)' then 'Household'
    else 'Other'
  end
  from (select ' ' || lower(p_name) || ' ' as n) s;
$$;

grant execute on function public.create_list(text, text) to authenticated;
grant execute on function public.create_list_invite(uuid) to authenticated;
grant execute on function public.join_list(text) to authenticated;
grant execute on function public.add_recipe_to_list(uuid) to authenticated;
grant execute on function public.remove_recipe_from_list(uuid) to authenticated;
grant execute on function public.save_recipe(uuid, uuid, text, jsonb) to authenticated;
grant execute on function public.clear_checked_items(uuid) to authenticated;
grant execute on function public.categorize_item(text) to authenticated;

-- ---------------------------------------------------------------- realtime

alter publication supabase_realtime add table
  public.lists,
  public.list_members,
  public.items,
  public.recipes,
  public.recipe_ingredients;

-- ----------------------------------------------------------------- storage

-- Public-read bucket for generated meal images. Only the edge function (service
-- role) writes to it; object names are random UUIDs.
insert into storage.buckets (id, name, public)
values ('recipe-images', 'recipe-images', true)
on conflict (id) do nothing;
