-- "Watch how to make it": YouTube videos for a meal, found by the find-videos
-- edge function (YouTube Data API) and cached per meal so each meal is looked
-- up once. The cache is written only by the function (service role); list
-- members can read it.

create table public.recipe_videos (
  recipe_id uuid primary key references public.recipes (id) on delete cascade,
  list_id uuid not null references public.lists (id) on delete cascade,
  -- The meal name the videos were found for; a rename looks again.
  query_name text not null,
  -- [{ id, title, channel, thumbnail, seconds, views, published_at }]
  videos jsonb not null default '[]',
  fetched_at timestamptz not null default now()
);
create index recipe_videos_list_idx on public.recipe_videos (list_id);

alter table public.recipe_videos enable row level security;
create policy "recipe videos: members read" on public.recipe_videos
  for select to authenticated using (public.is_list_member(list_id));
grant select on public.recipe_videos to authenticated;
grant all on public.recipe_videos to service_role;

-- YouTube search costs 100 of the free 10,000 daily quota units, so keep the
-- global cap under 100 lookups a day (cached results don't count).
insert into public.ai_limits (kind, burst_window, burst_max, user_per_day, global_per_day,
                              burst_message, user_day_message, global_message) values
  ('videos', '10 minutes', 15, 40, 90,
   'Lamar has been watching a lot of cooking videos. Try again in a few minutes.',
   'Lamar has watched enough videos for today. Try again tomorrow.',
   'Lamar''s TV time is up for today. Videos will be back tomorrow.')
on conflict (kind) do nothing;
