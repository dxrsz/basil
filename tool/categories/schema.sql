-- Item categories (aisles) that are actually right.
--
-- Before: keyword rules only, first substring match wins, so "Eggplant" was
-- Dairy & Eggs, "Peanut butter" Dairy, "Chicken broth" Meat, "Tofu" Other.
--
-- Now, whenever an item is added or renamed (typed, from a meal, imported,
-- replayed from offline, Tidy up), a trigger picks its aisle from:
--   1. this list's own choice (list_item_categories): someone moved it
--   2. the shared cache (item_categories): a hand-written core list of
--      everyday items, ~3,800 USDA FoodData Central foods (public domain)
--      turned into shopping-list names, and items Lamar has classified
--   3. keyword rules (categorize_item_rules), as a last resort
-- Names the cache doesn't know are queued; the classify-items edge function
-- (kicked by pg_net, plus a cron backstop) asks the model once, caches the
-- answer for everyone and moves the item.
--
-- The cache is built partly from names people type, so it's not readable
-- through the API: only security-definer functions and the edge function
-- (service role) use it.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ------------------------------------------------------------------ rules

-- @@RULES@@

revoke execute on function public.categorize_item_rules(text) from public, anon;
grant execute on function public.categorize_item_rules(text) to authenticated, service_role;

-- ------------------------------------------------------------------ cache

create table public.item_categories (
  name_key text primary key,
  category text not null check (category in
    ('Produce', 'Meat', 'Seafood', 'Dairy & Eggs', 'Bakery', 'Pantry', 'Frozen', 'Drinks', 'Household', 'Other')),
  -- core (hand-written) | usda | ai
  source text not null check (source in ('core', 'usda', 'ai')),
  updated_at timestamptz not null default now()
);
alter table public.item_categories enable row level security;   -- no policies: not readable via the API
grant all on public.item_categories to service_role;

-- Several seed names can normalise to one key ("Egg" / "eggs"): keep one per
-- key, preferring the hand-written core list over USDA.
insert into public.item_categories (name_key, category, source)
select distinct on (k) k, c, src
from (
  select public.normalize_item_name(n) as k, c, src
  from (values
-- @@SEED@@
  ) as v(n, c, src)
) x
where k <> ''
order by k, (src = 'core') desc, c
on conflict (name_key) do nothing;

-- A list's own choices: "this list keeps tortillas in the deli".
create table public.list_item_categories (
  list_id uuid not null references public.lists (id) on delete cascade,
  name_key text not null,
  category text not null check (category in
    ('Produce', 'Meat', 'Seafood', 'Dairy & Eggs', 'Bakery', 'Pantry', 'Frozen', 'Drinks', 'Household', 'Other')),
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (list_id, name_key)
);
alter table public.list_item_categories enable row level security;
create policy "list item categories: members read" on public.list_item_categories
  for select to authenticated using (public.is_list_member(list_id));
grant select on public.list_item_categories to authenticated;
grant all on public.list_item_categories to service_role;

-- Names waiting for the model.
create table private.category_queue (
  name_key text primary key,
  name text not null,
  queued_at timestamptz not null default now()
);

create table private.classify_config (
  id int primary key default 1 check (id = 1),
  -- The deployed classify-items function. For another project:
  --   update private.classify_config set function_url = 'https://<ref>.supabase.co/functions/v1/classify-items';
  function_url text,
  secret text not null default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
);
insert into private.classify_config (function_url)
values ('https://mrlumpodeelalofbdzpa.supabase.co/functions/v1/classify-items');

-- -------------------------------------------------------------- resolution

-- Cache, then rules (no list context): used where only a name is known.
create or replace function public.categorize_item(p_name text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select category from public.item_categories where name_key = public.normalize_item_name(p_name)),
    public.categorize_item_rules(p_name)
  );
$$;

-- The list's choice, then the cache, then the rules.
create or replace function public.resolve_item_category(p_list_id uuid, p_name text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select category from public.list_item_categories
      where list_id = p_list_id and name_key = public.normalize_item_name(p_name)),
    (select category from public.item_categories where name_key = public.normalize_item_name(p_name)),
    public.categorize_item_rules(p_name)
  );
$$;

-- Asks classify-items to work through the queue (pg_net sends after commit).
create or replace function public.kick_classify()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
  v_secret text;
begin
  select function_url, secret into v_url, v_secret from private.classify_config where id = 1;
  if v_url is null then
    return;
  end if;
  perform net.http_post(
    url := v_url,
    body := '{"type":"drain"}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-classify-secret', v_secret),
    timeout_milliseconds := 10000
  );
end;
$$;

create or replace function public.classify_secret_matches(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select secret = p_secret from private.classify_config where id = 1), false);
$$;

-- On insert, or when the name changes: pick the aisle, and queue names the
-- cache doesn't know (kicking the classifier once per transaction).
create or replace function public.set_item_category()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_key text := public.normalize_item_name(new.name);
  v_known boolean;
begin
  if tg_op = 'UPDATE' and new.name is not distinct from old.name then
    return new;   -- an explicit category change (someone moved it) stands
  end if;
  new.category := public.resolve_item_category(new.list_id, new.name);

  v_known := v_key = ''
    or exists (select 1 from public.item_categories where name_key = v_key)
    or exists (select 1 from public.list_item_categories where list_id = new.list_id and name_key = v_key);
  if not v_known then
    insert into private.category_queue (name_key, name) values (v_key, left(new.name, 80))
    on conflict do nothing;
    if found and current_setting('lamar.classify_kicked', true) is distinct from 'on' then
      perform set_config('lamar.classify_kicked', 'on', true);
      perform public.kick_classify();
    end if;
  end if;
  return new;
end;
$$;

create trigger items_set_category
  before insert or update of name on public.items
  for each row execute function public.set_item_category();

-- ------------------------------------------------------ for classify-items

-- Takes up to p_limit queued names.
create or replace function public.claim_category_queue(p_limit int default 60)
returns table (name_key text, name text)
language sql
security definer
set search_path = public
as $$
  delete from private.category_queue q
  where q.name_key in (select c.name_key from private.category_queue c order by c.queued_at limit p_limit)
  returning q.name_key, q.name;
$$;

-- Caches the model's answers ([{ key, category }]) and moves matching items
-- on every list that hasn't made its own choice. Returns items moved.
create or replace function public.apply_ai_categories(p_answers jsonb)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_moved int;
begin
  insert into public.item_categories (name_key, category, source)
  select a ->> 'key', a ->> 'category', 'ai'
  from jsonb_array_elements(p_answers) a
  where coalesce(a ->> 'key', '') <> ''
  on conflict (name_key) do nothing;

  update public.items i
  set category = c.category
  from public.item_categories c
  where c.name_key = public.normalize_item_name(i.name)
    and c.name_key in (select a ->> 'key' from jsonb_array_elements(p_answers) a)
    and i.category is distinct from c.category
    and not exists (
      select 1 from public.list_item_categories l
      where l.list_id = i.list_id and l.name_key = c.name_key
    );
  get diagnostics v_moved = row_count;
  return v_moved;
end;
$$;

-- Puts names back in the queue after a failed batch ([{ name_key, name }]).
create or replace function public.requeue_category_names(p_names jsonb)
returns void
language sql
security definer
set search_path = public
as $$
  insert into private.category_queue (name_key, name)
  select x ->> 'name_key', x ->> 'name' from jsonb_array_elements(p_names) x
  where coalesce(x ->> 'name_key', '') <> ''
  on conflict do nothing;
$$;

-- How many names the model classified in the last day (the function's cap).
create or replace function public.ai_categories_today()
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int from public.item_categories where source = 'ai' and updated_at > now() - interval '1 day';
$$;

revoke execute on function public.kick_classify(), public.classify_secret_matches(text),
  public.claim_category_queue(int), public.apply_ai_categories(jsonb), public.ai_categories_today(),
  public.requeue_category_names(jsonb), public.set_item_category()
  from public, anon, authenticated;
grant execute on function public.classify_secret_matches(text), public.claim_category_queue(int),
  public.apply_ai_categories(jsonb), public.ai_categories_today(), public.requeue_category_names(jsonb)
  to service_role;

-- ------------------------------------------------------- moving an item

-- "Move to aisle…": remembers the choice for this list and moves every
-- unchecked item with the same name. Returns items moved.
create or replace function public.move_item_category(p_item_id uuid, p_category text)
returns int
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_item public.items%rowtype;
  v_key text;
  v_moved int;
begin
  select * into v_item from public.items where id = p_item_id;
  if not found then
    raise exception 'item not found' using errcode = 'P0002';
  end if;
  v_key := public.normalize_item_name(v_item.name);
  insert into public.list_item_categories (list_id, name_key, category)
  values (v_item.list_id, v_key, p_category)
  on conflict (list_id, name_key) do update
    set category = excluded.category, updated_by = auth.uid(), updated_at = now();
  update public.items set category = p_category
  where list_id = v_item.list_id
    and (id = p_item_id or (not checked and public.normalize_item_name(name) = v_key));
  get diagnostics v_moved = row_count;
  return v_moved;
end;
$$;

-- Writing list_item_categories goes through move_item_category (members only, via RLS on items).
create policy "list item categories: members write" on public.list_item_categories
  for insert to authenticated with check (public.is_list_member(list_id));
create policy "list item categories: members update" on public.list_item_categories
  for update to authenticated using (public.is_list_member(list_id));
grant insert, update on public.list_item_categories to authenticated;
grant execute on function public.move_item_category(uuid, text) to authenticated;

-- Backstop: drain anything left in the queue every 10 minutes.
select cron.schedule(
  'classify-items',
  '*/10 * * * *',
  $$select public.kick_classify() where exists (select 1 from private.category_queue)$$
);

-- ------------------------------------------------- fix existing items

update public.items i
set category = public.resolve_item_category(i.list_id, i.name)
where i.category is distinct from public.resolve_item_category(i.list_id, i.name);
