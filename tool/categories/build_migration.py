"""Builds the item-categories migration: schema + rules + seed data.

Seed = core.json (hand-written everyday items) overriding usda_pairs.json
(USDA FoodData Central SR Legacy, public domain, turned into shopping-list
names by the model once and reviewed). Run from the repo root:

    python3 tool/categories/build_migration.py > supabase/migrations/20261005180000_item_categories.sql
"""
import json, pathlib

here = pathlib.Path(__file__).parent
AISLES = ["Produce", "Meat", "Seafood", "Dairy & Eggs", "Bakery", "Pantry", "Frozen", "Drinks", "Household", "Other"]

seed = {}
for name, aisle in json.load(open(here / "usda_pairs.json")):
    seed[name.lower().strip()] = (aisle, "usda")
for aisle, names in json.load(open(here / "core.json")).items():
    for name in names:
        seed[name.lower().strip()] = (aisle, "core")
assert all(a in AISLES for a, _ in seed.values())

def q(s):
    return "'" + s.replace("'", "''") + "'"

values = ",\n".join(f"  ({q(n)}, {q(a)}, {q(src)})" for n, (a, src) in sorted(seed.items()))
schema = (here / "schema.sql").read_text()
rules = (here / "rules.sql").read_text()
print(schema.replace("-- @@RULES@@", rules).replace("-- @@SEED@@", values))
