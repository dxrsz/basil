// Classifies grocery item names the shared category cache doesn't know yet.
//
// Called by the database (set_item_category trigger via pg_net, plus a cron
// backstop) with x-classify-secret, never by the app. Drains
// private.category_queue in batches: asks the model for each name's aisle,
// caches the answers for everyone (apply_ai_categories) and moves matching
// items on lists that haven't made their own choice.
//
// Each name is classified once, ever (then it's cached), and at most
// DAILY_CAP new names a day, so cost stays bounded however many people type.

import { json } from "../_shared/cors.ts";
import { adminClient } from "../_shared/clients.ts";
import { structured } from "../_shared/openai.ts";

const AISLES = ["Produce", "Meat", "Seafood", "Dairy & Eggs", "Bakery", "Pantry", "Frozen", "Drinks", "Household", "Other"];
const BATCH = 60;
const MAX_BATCHES = 5;
const DAILY_CAP = 1500;

const schema = {
  type: "object",
  additionalProperties: false,
  required: ["answers"],
  properties: {
    answers: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["i", "aisle"],
        properties: { i: { type: "integer" }, aisle: { type: "string", enum: AISLES } },
      },
    },
  },
};

const SYSTEM = `You sort grocery shopping-list items into supermarket aisles. For each numbered item, pick where a typical US/UK supermarket shelves it:
Produce (fresh fruit, vegetables, fresh herbs, tofu), Meat (incl. deli meat, sausages), Seafood, Dairy & Eggs (milk incl. plant milks, cheese, yogurt, butter, cream, eggs), Bakery (bread, tortillas, buns, pastries), Pantry (dry and canned goods, spices, oils, sauces, condiments, pasta, rice, noodles, flour, sugar, snacks, cereal, nut butters, broth), Frozen, Drinks (incl. juice, soda, coffee, tea, alcohol), Household (cleaning, paper goods, toiletries, pet supplies, baby supplies), Other (anything else, or if it isn't a grocery item).
Judge by what the item is, not by words inside it ("peanut butter" is Pantry, "eggplant" is Produce). Return one answer per item.`;

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const db = adminClient();

  const secret = req.headers.get("x-classify-secret") ?? "";
  const { data: ok } = await db.rpc("classify_secret_matches", { p_secret: secret });
  if (!secret || ok !== true) return json({ error: "forbidden" }, 401);

  let classified = 0, moved = 0;
  for (let b = 0; b < MAX_BATCHES; b++) {
    const { data: today } = await db.rpc("ai_categories_today");
    if ((today ?? 0) >= DAILY_CAP) {
      console.warn("classify-items: daily cap reached; leaving the queue for tomorrow");
      break;
    }
    const { data: claimed, error: claimErr } = await db.rpc("claim_category_queue", { p_limit: BATCH });
    if (claimErr) {
      console.error("classify-items: claim failed", claimErr.message);
      break;
    }
    const batch = (claimed ?? []) as { name_key: string; name: string }[];
    if (batch.length === 0) break;

    try {
      const out = await structured<{ answers: { i: number; aisle: string }[] }>(
        SYSTEM,
        batch.map((x, i) => `${i}. ${x.name}`).join("\n"),
        "aisles",
        schema,
      );
      const answers = out.answers
        .filter((a) => Number.isInteger(a.i) && a.i >= 0 && a.i < batch.length && AISLES.includes(a.aisle))
        .map((a) => ({ key: batch[a.i].name_key, category: a.aisle }));
      const { data: n, error: applyErr } = await db.rpc("apply_ai_categories", { p_answers: answers });
      if (applyErr) throw applyErr;
      classified += answers.length;
      moved += n ?? 0;
    } catch (e) {
      // Put the batch back so the cron backstop retries it later.
      console.error("classify-items: batch failed", e instanceof Error ? e.message : e);
      await db.rpc("requeue_category_names", { p_names: batch });
      break;
    }
  }
  return json({ classified, moved });
});
