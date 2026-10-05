-- Account & privacy: AI consent, account deletion support, Apple token
-- storage (so deleting an account can revoke Sign in with Apple, which Apple
-- requires).

-- ------------------------------------------------------------ AI consent

-- Lamar's AI helpers send meal names, list items and imported photos to
-- OpenAI. Apple requires asking first, and under GDPR it's consent-based, so
-- every AI call checks this (consume_ai_quota is the single choke point).
alter table public.profiles
  add column ai_consent text check (ai_consent in ('granted', 'declined')),
  add column ai_consent_at timestamptz;

create or replace function public.ai_consent_granted(p_user uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select ai_consent = 'granted' from public.profiles where id = p_user), false);
$$;
revoke execute on function public.ai_consent_granted(uuid) from public, anon, authenticated;
grant execute on function public.ai_consent_granted(uuid) to service_role;

-- ------------------------------------------------------- Apple tokens

-- Apple refresh tokens, kept only to revoke Sign in with Apple when someone
-- deletes their account. Service role only.
create schema if not exists private;
create table private.apple_tokens (
  user_id uuid primary key references auth.users (id) on delete cascade,
  client_id text not null,          -- com.lamarsgroceries.app (native) or .signin (web)
  refresh_token text not null,
  updated_at timestamptz not null default now()
);

create or replace function public.save_apple_token(p_user uuid, p_client_id text, p_refresh_token text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into private.apple_tokens (user_id, client_id, refresh_token)
  values (p_user, p_client_id, p_refresh_token)
  on conflict (user_id) do update
    set client_id = excluded.client_id, refresh_token = excluded.refresh_token, updated_at = now();
$$;

create or replace function public.apple_token_for(p_user uuid)
returns table (client_id text, refresh_token text)
language sql
stable
security definer
set search_path = public
as $$
  select client_id, refresh_token from private.apple_tokens where user_id = p_user;
$$;

-- ---------------------------------------------------- account deletion

-- Before a user is deleted: lists they own and share pass to the member who
-- joined earliest (deleting the owner would otherwise cascade the whole list
-- away for everyone); lists only they use are deleted. Returns a summary.
create or replace function public.release_owned_lists(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  l record;
  v_heir uuid;
  v_handed int := 0;
  v_deleted int := 0;
begin
  for l in select id from public.lists where owner_id = p_user loop
    select user_id into v_heir from public.list_members
    where list_id = l.id and user_id <> p_user
    order by joined_at
    limit 1;
    if v_heir is null then
      delete from public.lists where id = l.id;
      v_deleted := v_deleted + 1;
    else
      update public.lists set owner_id = v_heir where id = l.id;
      update public.list_members set role = 'owner' where list_id = l.id and user_id = v_heir;
      v_handed := v_handed + 1;
    end if;
  end loop;
  return jsonb_build_object('handed_over', v_handed, 'deleted', v_deleted);
end;
$$;

revoke execute on function public.save_apple_token(uuid, text, text), public.apple_token_for(uuid),
  public.release_owned_lists(uuid) from public, anon, authenticated;
grant execute on function public.save_apple_token(uuid, text, text), public.apple_token_for(uuid),
  public.release_owned_lists(uuid) to service_role;
