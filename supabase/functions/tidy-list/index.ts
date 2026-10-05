// "Tidy up": reviews a list's unchecked items and proposes merges of
// near-duplicates ("Chicken thighs" + "2 lb chicken"), quantity consolidation
// and obvious corrections. Proposals only; nothing is changed here. The app
// shows them for review and applies the accepted ones with apply_tidy().
//
// POST { list_id: uuid }
// ->   { proposals: [{ kind: "merge" | "fix", item_ids: uuid[], name, quantity, reason }] }
//      item_ids[0] is the item to keep; the rest are merged into it.

import { error, json, preflight } from "../_shared/cors.ts";
import { consumeQuota, userClient } from "../_shared/clients.ts";
import { structured } from "../_shared/openai.ts";
import { safeFix, safeMerge, soundsUnsure } from "./guard.ts";

const MAX_ITEMS = 150;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Item = { id: string; name: string; quantity: string | null };
type Proposal = { kind: "merge" | "fix"; items: number[]; name: string; quantity: string | null; reason: string };

const schema = {
  type: "object",
  additionalProperties: false,
  required: ["proposals"],
  properties: {
    proposals: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["kind", "items", "name", "quantity", "reason"],
        properties: {
          kind: { type: "string", enum: ["merge", "fix"] },
          items: {
            type: "array",
            items: { type: "integer" },
            description: "Line numbers. merge: 2 or more (the best-named first); fix: exactly 1.",
          },
          name: { type: "string", description: "The resulting item name, 1-4 words, e.g. 'Chicken thighs'" },
          quantity: {
            type: ["string", "null"],
            description: "The resulting combined quantity, e.g. '3 lb' or '1 bunch + 2'; null if none",
          },
          reason: { type: "string", description: "A short phrase, at most 8 words" },
        },
      },
    },
  },
};

const SYSTEM = `You tidy up a shared grocery shopping list. You get its unchecked items as numbered lines "N. name · quantity".
Propose only changes a shopper would clearly welcome:

- "merge": two or more lines that are the same thing to buy: near-duplicates, synonyms, or a vague and a specific version of the same product ("Chicken" + "Chicken thighs" → "Chicken thighs"; "Scallions" + "Green onions"). Combine the quantities into one sensible quantity, adding amounts in compatible units ("1 lb" + "2 lb" → "3 lb", "8 oz" + "1 lb" → "1.5 lb"); if they can't be added, join them with " + ".
- "fix": one line with an obvious mistake: a misspelling ("Tomatos" → "Tomatoes"), or a quantity stuck in the name ("Eggs 12" → name "Eggs", quantity "12").

Never merge different products, even similar ones: lemons vs limes, chicken breasts vs chicken thighs, milk vs oat milk, red onion vs green onion, potatoes vs sweet potatoes. Never merge items just because they'd be cooked together or sit in the same aisle (eggs + ramen, yogurt + spinach): a merge means it's literally the same thing written twice.
Never change items just for style or capitalisation. Keep the existing quantity when it doesn't change.
Each line appears in at most one proposal. Only propose what you're sure of; if in doubt, leave it out. If the list is already tidy, return an empty array; silence is better than noise. At most 15 proposals. The reason is a plain description of the change, never commentary.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return error("POST only", 405);

  const db = userClient(req);
  const { data: auth } = await db.auth.getUser();
  if (!auth.user) return error("Not signed in", 401);

  let body: { list_id?: string };
  try {
    body = await req.json();
  } catch {
    return error("Invalid JSON");
  }
  const listId = String(body.list_id ?? "");
  if (!UUID.test(listId)) return error("list_id is required");

  // RLS: only members can see the list or its items.
  const { data: list } = await db.from("lists").select("id").eq("id", listId).maybeSingle();
  if (!list) return error("List not found", 404);

  const { data: rows, error: readError } = await db
    .from("items")
    .select("id, name, quantity")
    .eq("list_id", listId)
    .eq("checked", false)
    .order("created_at")
    .limit(MAX_ITEMS);
  if (readError) {
    console.error(readError);
    return error("Couldn't read the list", 500);
  }
  const items = (rows ?? []) as Item[];
  if (items.length < 2) return json({ proposals: [] });

  const limited = await consumeQuota(auth.user.id, "tidy");
  if (limited) return error(limited, 429);

  const lines = items.map((it, i) => `${i + 1}. ${it.name}${it.quantity ? ` · ${it.quantity}` : ""}`).join("\n");

  let result: { proposals: Proposal[] };
  try {
    result = await structured<{ proposals: Proposal[] }>(SYSTEM, lines, "list_tidy", schema);
  } catch (e) {
    console.error(e);
    return error("Lamar couldn't tidy up right now", 502);
  }

  // Never trust the model's line numbers: keep only well-formed, real,
  // non-overlapping proposals that actually change something.
  const used = new Set<number>();
  const proposals = [];
  for (const p of result.proposals.slice(0, 15)) {
    const idx = [...new Set(p.items)].map((n) => n - 1);
    if (idx.some((i) => !Number.isInteger(i) || i < 0 || i >= items.length || used.has(i))) continue;
    if (p.kind === "merge" ? idx.length < 2 : idx.length !== 1) continue;
    const name = p.name.trim().slice(0, 120);
    const quantity = p.quantity?.trim().slice(0, 60) || null;
    if (!name) continue;
    if (p.kind === "fix") {
      const it = items[idx[0]];
      if (it.name === name && (it.quantity ?? null) === quantity) continue;
      if (!safeFix(it.name, name)) continue;
    } else if (!safeMerge(idx.map((i) => items[i].name), name)) {
      continue; // e.g. "Green onion" + "Red onion", "Eggs" + "Ramen"
    }
    if (soundsUnsure(name, quantity ?? "", p.reason)) continue; // the model second-guessing itself
    idx.forEach((i) => used.add(i));
    proposals.push({
      kind: p.kind,
      item_ids: idx.map((i) => items[i].id),
      name,
      quantity,
      reason: p.reason.trim().slice(0, 80),
    });
  }
  return json({ proposals });
});
