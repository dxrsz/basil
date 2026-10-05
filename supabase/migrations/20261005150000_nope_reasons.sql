-- "Nope!" on a planned meal: the household says why they passed on it, and
-- Lamar remembers. Ingredient and spice reasons become profile changes (made
-- by the plan-meals function on the user's own taste profile); everything
-- else is remembered here as a 'noped' meal event with a reason_kind, and
-- summarised into planner_context so future plans lean away from it.

alter table public.meal_events drop constraint meal_events_kind_check;
alter table public.meal_events add constraint meal_events_kind_check
  check (kind in ('kept', 'swapped', 'nudged', 'noped', 'added', 'cooked', 'rated'));

-- noped: why. ingredient | spice | cuisine | effort | heavy | light | recent | mood | other
alter table public.meal_events add column reason_kind text
  check (reason_kind in ('ingredient', 'spice', 'cuisine', 'effort', 'heavy', 'light', 'recent', 'mood', 'other'));
alter table public.meal_events add constraint meal_events_reason_only_for_nope
  check (reason_kind is null or kind = 'noped');

-- Microwave and oven are near-universal; start new kitchens with both.
alter table public.kitchen_settings alter column appliances set default '{oven,microwave}';

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
        select meal_name from recent where kind in ('swapped', 'noped')
        group by meal_name order by max(created_at) desc limit 15
      ) s
    ), '[]'),
    'nudges', coalesce((
      select jsonb_agg(detail) from (
        select detail from recent where kind = 'nudged' and detail is not null
        group by detail order by count(*) desc, max(created_at) desc limit 8
      ) s
    ), '[]'),
    -- Why they've said "Nope!" lately (last 60 days), most common first:
    -- [{ kind, count, examples: [reason text…] }]
    'nope_reasons', coalesce((
      select jsonb_agg(jsonb_build_object('kind', reason_kind, 'count', n, 'examples', examples) order by n desc)
      from (
        select reason_kind, count(*) as n,
               (array_agg(distinct detail) filter (where detail is not null))[1:4] as examples
        from recent
        where kind = 'noped' and reason_kind is not null and created_at > now() - interval '60 days'
        group by reason_kind
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
