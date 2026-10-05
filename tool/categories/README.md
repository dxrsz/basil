# Item categories (aisles)

How an item gets its aisle, in order (database trigger `set_item_category`,
on insert and rename):

1. **This list's choice** (`list_item_categories`): someone moved it with
   press-and-hold → edit → Aisle.
2. **The shared cache** (`item_categories`, not readable through the API):
   - `core.json`: ~500 hand-written everyday items (wins over USDA)
   - `usda_pairs.json`: ~3,800 names from USDA FoodData Central SR Legacy
     (public domain), turned into shopping-list names by the model once and
     reviewed (food group → aisle, brands and prepared dishes dropped)
   - `ai`: names Lamar classified later (see below)
3. **Keyword rules** (`rules.sql`, mirrored in `lib/util/categories.dart`):
   whole words, specific phrases first. Both copies must agree with
   `test/fixtures/category_cases.json`.

Names not in the cache are queued (`private.category_queue`); the trigger
kicks the `classify-items` edge function via pg_net (a cron job re-kicks
every 10 minutes), which classifies each name once, caches it for everyone
and moves the items. Capped at 1,500 new names a day.

To change the seed or rules: edit `core.json` / `rules.sql` (and the Dart
mirror), then write a new migration (e.g. by adapting `build_migration.py`,
which generated `20261005180000_item_categories.sql`).
