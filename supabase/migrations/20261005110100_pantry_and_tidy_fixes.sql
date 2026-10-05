-- Follow-ups to 20261005110000_pantry_and_tidy.sql (already applied).
--
-- normalize_item_name: fold common accents so "Jalapeños" matches "jalapeno"
-- (previously "ñ" split the word). Mirrors lib/util/item_merge.dart.

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
  foreach w in array regexp_split_to_array(trim(regexp_replace(
    translate(lower(coalesce(p_name, '')), 'áàâäãåéèêëíìîïóòôöõúùûüñçœ', 'aaaaaaeeeeiiiiooooouuuunco'),
    '[^a-z0-9]+', ' ', 'g')), ' ')
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

-- Recompute what depends on it.
reindex index public.items_list_name_key_idx;
update public.pantry_staples set name = name;
