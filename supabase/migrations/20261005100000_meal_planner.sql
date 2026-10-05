-- Meal planner ("Plan my week with Lamar").
--
-- Model
--   taste_profiles   one row per user: personal things (diet, allergies,
--                    dislikes, tastes). Only the owner reads it directly;
--                    planning merges list members' rows via planner_context().
--   kitchen_settings one row per list: household things (how many eat, dinners
--                    per week, effort defaults, appliances).
--   meal_events      a list's meal memory: what was kept, swapped, nudged, put
--                    on the list, cooked and rated. Feeds planning prompts and
--                    "make again" / "how was it?" in the app.

-- ---------------------------------------------------------- taste_profiles

create table public.taste_profiles (
  user_id uuid primary key default auth.uid() references public.profiles (id) on delete cascade,
  -- vegetarian | vegan | pescatarian | gluten_free | dairy_free | nut_allergy |
  -- shellfish_allergy | halal | kosher (free-form keys; the app owns the list)
  diets text[] not null default '{}',
  -- Free text, one thing each: "mushrooms", "cilantro".
  dislikes text[] not null default '{}',
  cuisines text[] not null default '{}',
  -- 0 = no heat, 1 = mild, 2 = medium, 3 = bring it on
  spice smallint not null default 1 check (spice between 0 and 3),
  -- 0 = comfort food, 100 = surprise me
  adventurous smallint not null default 50 check (adventurous between 0 and 100),
  updated_at timestamptz not null default now(),
  check (cardinality(diets) <= 20 and cardinality(dislikes) <= 30 and cardinality(cuisines) <= 20)
);

create trigger taste_profiles_touch before update on public.taste_profiles
  for each row execute function public.touch_updated_at();

-- -------------------------------------------------------- kitchen_settings

create table public.kitchen_settings (
  list_id uuid primary key references public.lists (id) on delete cascade,
  household_size smallint not null default 2 check (household_size between 1 and 12),
  dinners_per_week smallint not null default 5 check (dinners_per_week between 1 and 7),
  -- weeknight time budget in minutes: 15 | 30 | 45 (45 = "45+")
  time_budget smallint not null default 30 check (time_budget in (15, 30, 45)),
  leftovers boolean not null default true,
  batch_cook boolean not null default false,
  appliances text[] not null default '{oven}',
  -- appliances they'd like to use more (a subset of appliances, by convention)
  want_more text[] not null default '{}',
  updated_by uuid default auth.uid() references auth.users (id) on delete set null,
  updated_at timestamptz not null default now(),
  check (cardinality(appliances) <= 20 and cardinality(want_more) <= 20)
);

create trigger kitchen_settings_touch before update on public.kitchen_settings
  for each row execute function public.touch_updated_at();

-- ------------------------------------------------------------- meal_events

create table public.meal_events (
  id uuid primary key default gen_random_uuid(),
  list_id uuid not null references public.lists (id) on delete cascade,
  recipe_id uuid references public.recipes (id) on delete set null,
  -- kept the meal name even if the recipe is deleted later, for the memory
  meal_name text not null check (char_length(meal_name) between 1 and 120),
  kind text not null check (kind in ('kept', 'swapped', 'nudged', 'added', 'cooked', 'rated')),
  -- rated: 1 = 👍, -1 = 👎
  rating smallint check (rating in (-1, 1)),
  -- nudged: what they asked for ("lighter"); swapped: nothing
  detail text check (char_length(detail) <= 200),
  user_id uuid default auth.uid() references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  check ((kind = 'rated') = (rating is not null))
);
create index meal_events_list_idx on public.meal_events (list_id, created_at desc);
create index meal_events_recipe_idx on public.meal_events (recipe_id);

-- Whenever a meal's ingredients land on the list (editor, detail screen,
-- planner, or any future add-to-list flow), note it in the meal memory. A
-- statement trigger so one add is one event; repeats within 12 hours (undo,
-- topping up the same meal) are ignored.
create or replace function public.log_meal_added()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.meal_events (list_id, recipe_id, meal_name, kind, user_id)
  select distinct n.list_id, n.recipe_id, r.name, 'added', auth.uid()
  from new_rows n
  join public.recipes r on r.id = n.recipe_id
  where n.recipe_id is not null
    and not exists (
      select 1 from public.meal_events e
      where e.recipe_id = n.recipe_id and e.kind = 'added' and e.created_at > now() - interval '12 hours'
    );
  return null;
end;
$$;

create trigger items_log_meal_added after insert on public.items
  referencing new table as new_rows
  for each statement execute function public.log_meal_added();

-- -------------------------------------------------------------------- RLS

alter table public.taste_profiles enable row level security;
alter table public.kitchen_settings enable row level security;
alter table public.meal_events enable row level security;

create policy "taste: own row" on public.taste_profiles
  for all to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy "kitchen: members all" on public.kitchen_settings
  for all to authenticated
  using (public.is_list_member(list_id))
  with check (public.is_list_member(list_id));

create policy "meal events: members read" on public.meal_events
  for select to authenticated using (public.is_list_member(list_id));
create policy "meal events: members add their own" on public.meal_events
  for insert to authenticated
  with check (
    public.is_list_member(list_id)
    and user_id = auth.uid()
    and (recipe_id is null or exists (select 1 from public.recipes r where r.id = recipe_id and r.list_id = list_id))
  );
-- Changing your mind about a rating replaces it.
create policy "meal events: delete own" on public.meal_events
  for delete to authenticated using (user_id = auth.uid() and public.is_list_member(list_id));

grant select, insert, update, delete on public.taste_profiles, public.kitchen_settings to authenticated;
grant select, insert, delete on public.meal_events to authenticated;
grant all on public.taste_profiles, public.kitchen_settings, public.meal_events to service_role;

-- ------------------------------------------------------- planner_context

-- Everything the planner needs to know about a list, merged across its
-- members, for the plan-meals edge function (called with the user's JWT).
-- Restrictions are a union (an allergy anywhere in the household counts),
-- spice is the most cautious member's, adventurousness the average. Other
-- members' profiles never leave the database individually.
create or replace function public.planner_context(p_list_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v jsonb;
begin
  if not public.is_list_member(p_list_id) then
    raise exception 'not a member of this list' using errcode = '42501';
  end if;

  with members as (
    select tp.* from public.list_members m
    join public.taste_profiles tp on tp.user_id = m.user_id
    where m.list_id = p_list_id
  ),
  recent as (
    select * from public.meal_events
    where list_id = p_list_id and created_at > now() - interval '120 days'
  ),
  -- latest rating per meal name wins
  ratings as (
    select distinct on (lower(meal_name)) meal_name, rating
    from recent where kind = 'rated'
    order by lower(meal_name), created_at desc
  )
  select jsonb_build_object(
    'household', (
      select to_jsonb(k) - 'list_id' - 'updated_by' - 'updated_at'
      from public.kitchen_settings k where k.list_id = p_list_id
    ),
    'members_with_profiles', (select count(*) from members),
    'diets', coalesce((select jsonb_agg(distinct d) from members, unnest(diets) d), '[]'),
    'dislikes', coalesce((select jsonb_agg(distinct lower(x)) from members, unnest(dislikes) x), '[]'),
    'cuisines', coalesce((select jsonb_agg(distinct c) from members, unnest(cuisines) c), '[]'),
    'spice', (select min(spice) from members),
    'adventurous', (select round(avg(adventurous)) from members),
    'liked', coalesce((select jsonb_agg(meal_name) from (select meal_name from ratings where rating = 1 limit 15) s), '[]'),
    'disliked', coalesce((select jsonb_agg(meal_name) from (select meal_name from ratings where rating = -1 limit 15) s), '[]'),
    'passed_on', coalesce((
      select jsonb_agg(meal_name) from (
        select meal_name from recent where kind = 'swapped'
        group by meal_name order by max(created_at) desc limit 15
      ) s
    ), '[]'),
    'nudges', coalesce((
      select jsonb_agg(detail) from (
        select detail from recent where kind = 'nudged' and detail is not null
        group by detail order by count(*) desc, max(created_at) desc limit 8
      ) s
    ), '[]'),
    'recent', coalesce((
      select jsonb_agg(meal_name) from (
        select meal_name from recent
        where kind in ('added', 'cooked', 'kept') and created_at > now() - interval '14 days'
        group by meal_name order by max(created_at) desc limit 15
      ) s
    ), '[]')
  ) into v;
  return v;
end;
$$;

revoke execute on function public.planner_context(uuid) from public, anon;
grant execute on function public.planner_context(uuid) to authenticated;
revoke execute on function public.log_meal_added() from public, anon, authenticated;

-- --------------------------------------------------------------- realtime

alter publication supabase_realtime add table public.meal_events;
