// Reviews a meal's ingredient list and suggests what's probably missing, or
// (mode = "autofill") proposes a full ingredient list from just the meal name.
//
// POST { meal: string, ingredients: string[], dismissed?: string[], mode?: "review" | "autofill" }
// ->   { suggestions: [{ name, quantity, reason, severity: "missing" | "optional" }] }

import { corsHeaders, error, json } from "../_shared/cors.ts";
import { userClient } from "../_shared/clients.ts";
import { structured } from "../_shared/openai.ts";

type Suggestion = {
  name: string;
  quantity: string | null;
  reason: string;
  severity: "missing" | "optional";
};

const schema = {
  type: "object",
  additionalProperties: false,
  required: ["suggestions"],
  properties: {
    suggestions: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["name", "quantity", "reason", "severity"],
        properties: {
          name: {
            type: "string",
            description: "One specific grocery item, 1-3 words, e.g. 'Jasmine rice'. Never 'X or Y'.",
          },
          quantity: {
            type: ["string", "null"],
            description: "Shopping quantity for ~4 servings, at most 3 words, e.g. '2 cups', '1 bunch', '1 lb'; null if obvious",
          },
          reason: { type: "string", description: "A short phrase, at most 8 words" },
          severity: { type: "string", enum: ["missing", "optional"] },
        },
      },
    },
  },
};

const REVIEW_SYSTEM = `You help people build grocery lists for meals they plan to cook.
You are given a meal name and the ingredients the user already associated with it.
Point out ingredients they are probably forgetting.

- "missing": a core component of the dish that is clearly absent (e.g. rice in a rice bowl, tortillas for tacos). Be confident; at most 4.
- "optional": a common, worthwhile addition (garnish, sauce, side). At most 3.
- Treat the user's items generously: "chicken thighs" covers chicken, "cotija" covers cheese, etc. Never suggest something they already have under another name.
- Assume a normal kitchen has salt, pepper, water and cooking oil; do not suggest those.
- Never suggest anything in the dismissed list.
- If the list already looks complete, return an empty array. Silence is better than noise.
Style: each suggestion is ONE specific item (pick the most typical, e.g. "Jasmine rice", not "Brown rice or quinoa"). Names 1-3 words. Quantities at most 3 words ("2 cups", "1 bottle"), no parentheses or ranges. Reasons are a short phrase.`;

const AUTOFILL_SYSTEM = `You help people build grocery lists for meals they plan to cook.
Given a meal name (and maybe a few ingredients already chosen), list the remaining groceries needed to make it for about 4 people.

- Mark every core ingredient as "missing" and nice-to-have extras as "optional" (at most 3 optional).
- Use short grocery-list names ("Red onion", "Jasmine rice"), not recipe steps.
- Don't repeat ingredients the user already has (even under another name) or anything in the dismissed list.
- Assume a normal kitchen has salt, pepper, water and cooking oil; do not list those.
- Keep it to what a typical home cook would buy: usually 5-12 items.
Style: each suggestion is ONE specific item (pick the most typical, e.g. "Jasmine rice", not "Brown rice or quinoa"). Names 1-3 words. Quantities at most 3 words ("2 cups", "1 bottle"), no parentheses or ranges. Reasons are a short phrase.`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return error("POST only", 405);

  // Require a signed-in user (verify_jwt also enforces this at the gateway).
  const { data: auth } = await userClient(req).auth.getUser();
  if (!auth.user) return error("Not signed in", 401);

  let body: { meal?: string; ingredients?: string[]; dismissed?: string[]; mode?: string };
  try {
    body = await req.json();
  } catch {
    return error("Invalid JSON");
  }

  const meal = (body.meal ?? "").trim().slice(0, 120);
  const ingredients = (body.ingredients ?? []).map((s) => String(s).trim()).filter(Boolean).slice(0, 60);
  const dismissed = (body.dismissed ?? []).map((s) => String(s).trim()).filter(Boolean).slice(0, 60);
  const autofill = body.mode === "autofill";
  if (!meal) return error("meal is required");

  const userPrompt = [
    `Meal: ${meal}`,
    `Ingredients already chosen: ${ingredients.length ? ingredients.join(", ") : "(none)"}`,
    `Dismissed suggestions (never suggest): ${dismissed.length ? dismissed.join(", ") : "(none)"}`,
  ].join("\n");

  try {
    const result = await structured<{ suggestions: Suggestion[] }>(
      autofill ? AUTOFILL_SYSTEM : REVIEW_SYSTEM,
      userPrompt,
      "ingredient_suggestions",
      schema,
    );

    // Belt and braces: drop anything the model echoed back that we already have.
    const have = new Set([...ingredients, ...dismissed].map((s) => s.toLowerCase()));
    const suggestions = result.suggestions.filter((s) => !have.has(s.name.trim().toLowerCase()));
    return json({ suggestions });
  } catch (e) {
    console.error(e);
    return error("Couldn't get suggestions right now", 502);
  }
});
