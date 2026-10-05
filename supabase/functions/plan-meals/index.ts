// Lamar's meal planner. Proposes dinners (names + ingredients only; photos
// are generated later, and only for meals the household keeps).
//
// POST { list_id, mode: "week" }
//   -> { summary, meals: [Meal] }            one per dinner this week
// POST { list_id, mode: "swap",  week: [Meal], index, avoid?: string[] }
// POST { list_id, mode: "nudge", week: [Meal], index, nudge: string }
//   -> { summary, meals: [Meal], week_notes } one replacement for week[index],
//                                             plus fresh reuse notes for every night
// POST { list_id, mode: "tonight", have: string[] }
//   -> { summary, meals: [Meal] }            2-3 ideas that use up what they have
//
// Meal = { name, pitch, minutes, effort, appliance, ingredients: [{ name, quantity, perishable }], reuse_note, day }
//
// Sharing perishables across the week is the planner's main trick. The model
// commits to which perishables it will share before it picks meals (schema
// order), and the "uses the rest of Monday's cilantro" notes are computed in
// notes.ts from the actual ingredients, so they're always true.
//
// The household's profile (merged across list members) and meal memory are
// read server-side through planner_context(), with the caller's JWT, so RLS
// decides what they can plan for.

import { error, json, preflight } from "../_shared/cors.ts";
import { consumeQuota, userClient } from "../_shared/clients.ts";
import { structured } from "../_shared/openai.ts";
import { type Meal, reuseNotes, usesUp } from "./notes.ts";
import { violations } from "./safety.ts";

type Plan = { shared_perishables: string[]; meals: Omit<Meal, "reuse_note">[]; summary: string };

type Context = {
  household: {
    household_size: number;
    dinners_per_week: number;
    time_budget: number;
    leftovers: boolean;
    batch_cook: boolean;
    appliances: string[];
    want_more: string[];
  } | null;
  members_with_profiles: number;
  diets: string[];
  dislikes: string[];
  cuisines: string[];
  spice: number | null;
  adventurous: number | null;
  liked: string[];
  disliked: string[];
  passed_on: string[];
  nudges: string[];
  recent: string[];
};

const DAY_NAMES = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
// Which nights to cook for N dinners a week, spread out so perishables can be
// shared between nearby nights.
const SPREAD: Record<number, number[]> = {
  1: [0],
  2: [0, 3],
  3: [0, 2, 4],
  4: [0, 1, 3, 4],
  5: [0, 1, 2, 3, 4],
  6: [0, 1, 2, 3, 4, 6],
  7: [0, 1, 2, 3, 4, 5, 6],
};
export function daysFor(n: number): string[] {
  return SPREAD[Math.min(7, Math.max(1, n))].map((i) => DAY_NAMES[i]);
}

const APPLIANCES: Record<string, string> = {
  oven: "oven / sheet pan",
  air_fryer: "air fryer",
  slow_cooker: "slow cooker",
  pressure_cooker: "Instant Pot / pressure cooker",
  rice_cooker: "rice cooker",
  grill: "grill",
  stand_mixer: "stand mixer",
  blender: "blender",
  wok: "wok",
  dutch_oven: "Dutch oven",
};
const DIETS: Record<string, string> = {
  vegetarian: "vegetarian (no meat or fish)",
  vegan: "vegan (no animal products at all)",
  pescatarian: "pescatarian (fish ok, no other meat)",
  gluten_free: "gluten-free",
  dairy_free: "dairy-free",
  nut_allergy: "NUT ALLERGY (no peanuts or tree nuts, not even as garnish or oil)",
  shellfish_allergy: "SHELLFISH ALLERGY (no shrimp, crab, lobster, mussels, clams, scallops)",
  halal: "halal (no pork or alcohol; halal meat)",
  kosher: "kosher-style (no pork or shellfish, never meat with dairy)",
};
const SPICE = ["no heat at all", "mild", "medium", "spicy"];

const ingredientSchema = {
  type: "object",
  additionalProperties: false,
  required: ["name", "quantity", "perishable"],
  properties: {
    name: { type: "string", description: "One grocery item, 1-3 words, e.g. 'Cilantro'" },
    quantity: {
      type: ["string", "null"],
      description: "Shopping quantity for this meal, at most 3 words, e.g. '1/2 bunch', '1 lb'",
    },
    perishable: { type: "boolean", description: "Spoils within about a week (fresh herbs, produce, dairy, meat)" },
  },
};

const mealSchema = {
  type: "object",
  additionalProperties: false,
  required: ["name", "pitch", "minutes", "effort", "appliance", "ingredients"],
  properties: {
    name: { type: "string", description: "Short, appetising meal name, 2-5 words, e.g. 'Chicken taco bowls'" },
    pitch: { type: "string", description: "One friendly line selling the meal, at most 14 words" },
    minutes: { type: "integer", description: "Realistic hands-on + cooking time in minutes" },
    effort: { type: "string", enum: ["easy", "medium", "project"] },
    appliance: {
      type: ["string", "null"],
      description: "Main appliance used, from the household's list (e.g. 'air fryer'); null for stovetop only",
    },
    ingredients: {
      type: "array",
      description: "The groceries for this meal, 4-12 items; skip salt, pepper, water, cooking oil",
      items: ingredientSchema,
    },
  },
};

const planSchema = {
  type: "object",
  additionalProperties: false,
  required: ["shared_perishables", "meals", "summary"],
  properties: {
    shared_perishables: {
      type: "array",
      description:
        "Decide this FIRST: the perishable ingredients (fresh herbs, greens, produce, dairy, a big pack of meat) you will buy once and use in two or more of the meals, using exactly the names you'll use in the ingredients. For tonight's ideas: which of their items you'll use up.",
      items: { type: "string" },
    },
    meals: { type: "array", items: mealSchema },
    summary: {
      type: "string",
      description:
        "At most two short sentences (under 35 words) in Lamar the cat's voice (third person, warm, a little playful) about the plan, e.g. which fresh ingredients get shared across nights. Normal sentence case, e.g. \"Lamar spread one bunch of cilantro over three nights.\"",
    },
  },
};

const SYSTEM = `You are Lamar, a tuxedo cat who plans dinners for a household and builds their grocery list.
Plan realistic home-cooked dinners a typical home cook can make, using the household's profile.

Hard rules (never break):
- Respect every diet and allergy listed. An allergen must not appear in any ingredient, sauce, or garnish.
- Don't even mention an allergen or forbidden food in a meal name or pitch (no "peanut-free peanut noodles", no "meatless burger"); pick dishes that are naturally free of it.
- Never use anything in the dislikes list, even as a minor ingredient.
- Never propose a meal they disliked or recently passed on, or anything in the "avoid" list.

Ingredient overlap is your superpower: deliberately reuse PERISHABLE ingredients across the week so nothing goes to waste.
If Monday uses half a bunch of cilantro, a later night should use the rest; same for herbs, greens, a big pack of chicken thighs, a tub of yogurt, half a cabbage.
Split quantities accordingly (e.g. "1/2 bunch" on each night) and use the exact same ingredient name across meals.
Plan the shared perishables first, then make sure each one really appears, under the same name, in the ingredients of every meal that uses it. Aim for at least two shared perishables across a week. Don't force it where it doesn't fit, and don't reuse the same main protein every night.

Fit their effort: weeknight meals should fit the time budget; weekends can be a bit more involved.
Prefer appliances they have, and especially ones they want to use more. Only name an appliance they have.
Lean towards meals and cuisines they liked; vary cuisines and proteins across the week; respect spice tolerance.
Adventurousness 0 means comfort food classics, 100 means new and surprising dishes.
Quantities are for the household size given. Assume salt, pepper, water and cooking oil are on hand; don't list them.
Style: ingredient names 1-3 words, one specific item each ("Jasmine rice", never "Rice or quinoa"). Quantities at most 3 words, no parentheses.`;

function describe(ctx: Context): string {
  const h = ctx.household;
  const lines: string[] = [];
  if (h) {
    lines.push(`Household: ${h.household_size} ${h.household_size === 1 ? "person" : "people"}.`);
    lines.push(`Weeknight time budget: ${h.time_budget >= 45 ? "45+ minutes, happy to cook" : `${h.time_budget} minutes max`}.`);
    lines.push(h.leftovers ? "Leftovers are welcome (a meal can be cooked big)." : "They don't like leftovers; size each meal for one sitting.");
    if (h.batch_cook) lines.push("They batch-cook on Sundays: something prepped Sunday can feed a weeknight.");
    const have = h.appliances.map((a) => APPLIANCES[a] ?? a);
    lines.push(`Appliances: ${have.length ? have.join(", ") : "stovetop only"}.`);
    if (h.want_more.length) lines.push(`Wants to use more: ${h.want_more.map((a) => APPLIANCES[a] ?? a).join(", ")}.`);
  } else {
    lines.push("Household: 2 people. Weeknight time budget: 30 minutes. Appliances: oven, stovetop.");
  }
  if (ctx.diets.length) lines.push(`Diets & allergies (whole household): ${ctx.diets.map((d) => DIETS[d] ?? d).join("; ")}.`);
  if (ctx.dislikes.length) lines.push(`Dislikes (never use): ${ctx.dislikes.join(", ")}.`);
  if (ctx.cuisines.length) lines.push(`Favourite cuisines: ${ctx.cuisines.join(", ")}.`);
  if (ctx.spice != null) lines.push(`Spice tolerance: ${SPICE[ctx.spice] ?? "mild"}.`);
  if (ctx.adventurous != null) lines.push(`Adventurousness: ${ctx.adventurous}/100.`);
  if (ctx.liked.length) lines.push(`Meals they loved (lean towards similar): ${ctx.liked.join(", ")}.`);
  if (ctx.disliked.length) lines.push(`Meals they didn't enjoy (avoid similar): ${ctx.disliked.join(", ")}.`);
  if (ctx.passed_on.length) lines.push(`Recently passed on: ${ctx.passed_on.join(", ")}.`);
  if (ctx.nudges.length) lines.push(`They often ask for: ${ctx.nudges.join(", ")}.`);
  if (ctx.recent.length) lines.push(`Already had in the last two weeks (don't repeat): ${ctx.recent.join(", ")}.`);
  return lines.join("\n");
}

function weekText(week: Meal[]): string {
  return week.map((m, i) =>
    `${m.day ?? `Night ${i + 1}`}: ${m.name} — ${m.ingredients.map((x) => `${x.name}${x.quantity ? ` (${x.quantity})` : ""}`).join(", ")}`
  ).join("\n");
}

// ------------------------------------------------------------- validation

const str = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

function cleanMeal(v: unknown): Meal | null {
  if (!v || typeof v !== "object") return null;
  const m = v as Record<string, unknown>;
  const name = str(m.name, 120);
  if (!name) return null;
  const ingredients = (Array.isArray(m.ingredients) ? m.ingredients : []).slice(0, 20).map((x) => {
    const i = (x ?? {}) as Record<string, unknown>;
    return { name: str(i.name, 80), quantity: str(i.quantity, 40) || null, perishable: i.perishable === true };
  }).filter((i) => i.name);
  return {
    name,
    pitch: str(m.pitch, 200),
    minutes: typeof m.minutes === "number" ? m.minutes : 30,
    effort: m.effort === "medium" || m.effort === "project" ? m.effort : "easy",
    appliance: str(m.appliance, 40) || null,
    ingredients,
    reuse_note: str(m.reuse_note, 120) || null,
    day: str(m.day, 20) || undefined,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight(req);
  if (req.method !== "POST") return error("POST only", 405);

  const client = userClient(req);
  const { data: auth } = await client.auth.getUser();
  if (!auth.user) return error("Not signed in", 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return error("Invalid JSON");
  }

  const listId = str(body.list_id, 64);
  const mode = body.mode;
  if (!listId) return error("list_id is required");
  if (mode !== "week" && mode !== "swap" && mode !== "nudge" && mode !== "tonight") {
    return error("mode must be week, swap, nudge or tonight");
  }

  const week = (Array.isArray(body.week) ? body.week : []).slice(0, 7).map(cleanMeal).filter((m): m is Meal => !!m);
  const index = typeof body.index === "number" ? body.index : -1;
  const nudge = str(body.nudge, 120);
  const avoid = (Array.isArray(body.avoid) ? body.avoid : []).map((s) => str(s, 120)).filter(Boolean).slice(0, 30);
  const have = (Array.isArray(body.have) ? body.have : []).map((s) => str(s, 80)).filter(Boolean).slice(0, 40);

  if ((mode === "swap" || mode === "nudge") && (index < 0 || index >= week.length)) {
    return error("index must point at a meal in week");
  }
  if (mode === "nudge" && !nudge) return error("nudge is required");
  if (mode === "tonight" && have.length === 0) return error("Tell Lamar what you have first");

  // RLS (inside planner_context) decides whether they can plan for this list.
  const { data: ctxData, error: ctxErr } = await client.rpc("planner_context", { p_list_id: listId });
  if (ctxErr) {
    return ctxErr.code === "42501" ? error("You're not a member of that list", 403) : error(ctxErr.message, 500);
  }
  const ctx = ctxData as Context;

  const limited = await consumeQuota(auth.user.id, "plan");
  if (limited) return error(limited, 429);

  const profile = describe(ctx);
  let prompt: string;
  let days: string[] = [];
  let want: number;

  switch (mode) {
    case "week": {
      days = daysFor(ctx.household?.dinners_per_week ?? 5);
      want = days.length;
      prompt = [
        profile,
        "",
        `Plan exactly ${want} dinners, in this order: ${days.join(", ")}.`,
        "Share perishables between nearby nights.",
      ].join("\n");
      break;
    }
    case "swap":
    case "nudge": {
      const target = week[index];
      want = 1;
      const others = week.filter((_, i) => i !== index);
      prompt = [
        profile,
        "",
        "This week's plan so far:",
        weekText(week),
        "",
        mode === "swap"
          ? `Replace ${target.day ?? "this night"}'s "${target.name}" with a completely different idea.`
          : `Rework ${target.day ?? "this night"}'s "${target.name}" so it is: ${nudge}. Keep the spirit if that still fits; otherwise pick a new dish that does.`,
        "Keep the household's rules. Where it fits, reuse perishables already bought for the other nights (same ingredient names).",
        `Avoid: ${[target.name, ...others.map((m) => m.name), ...avoid].join(", ")}.`,
        "Return exactly 1 meal.",
      ].join("\n");
      days = target.day ? [target.day] : [];
      break;
    }
    case "tonight": {
      want = 3;
      prompt = [
        profile,
        "",
        `What they have on hand right now: ${have.join(", ")}.`,
        "Suggest 3 clearly different dinners for tonight (different styles of dish, not three takes on one idea) that use up as much of that as possible (perishables first) and need few extra groceries.",
        "List the full ingredients for each meal, including what they already have.",
        "Use their items under the same names they gave. Respect the time budget.",
      ].join("\n");
      break;
    }
  }

  try {
    const ask = async (p: string) => {
      const plan = await structured<Plan>(SYSTEM, p, "meal_plan", planSchema);
      const meals: Meal[] = plan.meals.slice(0, want).map((m, i) => ({
        ...m,
        reuse_note: null,
        day: days[i] ?? undefined,
      }));
      const broken = meals.flatMap((m) => violations(m, ctx.diets, ctx.dislikes).map((v) => `"${m.name}" (${v})`));
      return { plan, meals, broken };
    };

    // The keyword safety net: one retry with the problems spelled out. Then,
    // night by night, take the retry's meal if it's safe, else the first
    // attempt's if that was, else leave the night out (one quota unit either way).
    const first = await ask(prompt);
    let { plan, meals } = first;
    let leftOut: string[] = [];
    if (first.broken.length) {
      console.warn("plan-meals: retrying after", first.broken);
      const second = await ask(
        `${prompt}\n\nYour previous answer broke the household's rules: ${first.broken.join("; ")}. ` +
          "Replace those meals with dishes that naturally avoid the problem, without mentioning it.",
      );
      const safe = (m?: Meal) => !!m && violations(m, ctx.diets, ctx.dislikes).length === 0;
      plan = second.plan;
      meals = [];
      for (let i = 0; i < Math.max(first.meals.length, second.meals.length); i++) {
        const pick = [second.meals[i], first.meals[i]].find(safe);
        if (pick) meals.push(pick);
      }
      leftOut = second.broken;
      if (meals.length < want) console.warn("plan-meals: left out", second.broken);
    }
    if (meals.length === 0) {
      return error("Lamar couldn't find something that suits everyone. Try again, or nudge it a different way?", 502);
    }

    switch (mode) {
      case "week": {
        const notes = reuseNotes(meals, plan.shared_perishables);
        return json({
          summary: plan.summary,
          meals: meals.map((m, i) => ({ ...m, reuse_note: notes[i] })),
          ...(meals.length < want ? { left_out: leftOut } : {}),
        });
      }
      case "swap":
      case "nudge": {
        const next = week.map((m, i) => (i === index ? meals[0] : m));
        const notes = reuseNotes(next, plan.shared_perishables);
        return json({ summary: plan.summary, meals: [{ ...meals[0], reuse_note: notes[index] }], week_notes: notes });
      }
      case "tonight":
        return json({ summary: plan.summary, meals: meals.map((m) => ({ ...m, reuse_note: usesUp(m, have) })) });
    }
  } catch (e) {
    console.error(e);
    return error("Lamar couldn't plan right now. Try again in a moment.", 502);
  }
});
