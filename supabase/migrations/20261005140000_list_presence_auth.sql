-- "Who's shopping now": Realtime Presence on a private per-list channel.
--
-- The app joins `presence:list:<list uuid>` with `private: true`, so Realtime
-- checks these policies (Realtime Authorization) when a client joins: only
-- members of the list may receive its presence state (select) or track
-- themselves on it (insert). Non-members are refused at join time.

-- Parses the list id out of a presence topic; null for anything else, so the
-- policies below never match other channels (and never raise on bad input).
create or replace function public.presence_topic_list_id(p_topic text)
returns uuid
language sql
immutable
set search_path = public
as $$
  select case
    when p_topic ~ '^presence:list:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    then substr(p_topic, 15)::uuid
  end;
$$;

grant execute on function public.presence_topic_list_id(text) to authenticated, service_role;
revoke execute on function public.presence_topic_list_id(text) from anon;

create policy "list presence: members receive" on realtime.messages
  for select to authenticated
  using (
    realtime.messages.extension = 'presence'
    and public.is_list_member(public.presence_topic_list_id(realtime.topic()))
  );

create policy "list presence: members track" on realtime.messages
  for insert to authenticated
  with check (
    realtime.messages.extension = 'presence'
    and public.is_list_member(public.presence_topic_list_id(realtime.topic()))
  );
