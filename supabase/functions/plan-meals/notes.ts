// Reuse notes for the meal planner: which perishables a night shares with
// another, computed from the actual ingredients so the cards never claim an
// overlap that isn't there. Pure functions (no Deno APIs), so they can be
// tested with plain Node: node --experimental-strip-types notes_test.ts

export type Ingredient = { name: string; quantity: string | null; perishable: boolean };
export type Meal = {
  name: string;
  pitch: string;
  minutes: number;
  effort: "easy" | "medium" | "project";
  appliance: string | null;
  ingredients: Ingredient[];
  reuse_note: string | null;
  day?: string;
  nope_guesses?: { label: string; kind: string; value: string }[];
};

/** Loose grocery-name key: "Limes" == "lime", "Tomatoes" == "tomato". */
export function itemKey(name: string): string {
  const k = name.toLowerCase().replace(/[^a-z ]/g, "").replace(/\s+/g, " ").trim();
  if (k.endsWith("ies")) return k.slice(0, -3) + "y";
  if (k.endsWith("oes")) return k.slice(0, -2);
  if (k.endsWith("s") && !k.endsWith("ss")) return k.slice(0, -1);
  return k;
}

/** "cilantro", "cilantro and lime", "cilantro, lime and basil". */
function listOf(names: string[], max = 2): string {
  const n = names.map((x) => x.toLowerCase());
  if (n.length === 1) return n[0];
  if (n.length <= max) return `${n.slice(0, -1).join(", ")} and ${n[n.length - 1]}`;
  return `${n.slice(0, max).join(", ")} and more`;
}

// Technically perishable, but they keep for weeks: sharing them isn't news.
const KEEPS = new Set([
  "onion",
  "yellow onion",
  "red onion",
  "white onion",
  "sweet onion",
  "garlic",
  "garlic clove",
  "potato",
  "sweet potato",
  "russet potato",
  "shallot",
  "carrot",
]);

/**
 * For each night, the perishables it shares with another night, from the
 * actual ingredients: "Uses the rest of Monday's cilantro" (bought earlier) or
 * "Shares the basil with Friday" (finished later). Null when it shares none.
 * Of several nights to mention, the one sharing the most wins, counting the
 * perishables the model planned to share ([planned]) double.
 */
export function reuseNotes(meals: Meal[], planned: string[] = []): (string | null)[] {
  const plannedKeys = new Set(planned.map(itemKey));
  const keys = meals.map((m) => new Map(m.ingredients.map((i) => [itemKey(i.name), i])));
  const label = (j: number) => meals[j].day ?? `the ${meals[j].name}`;
  const sharedWith = (i: number, j: number) =>
    meals[i].ingredients
      .filter((x) => {
        const k = itemKey(x.name);
        const other = keys[j].get(k);
        return other && (x.perishable || other.perishable) && !KEEPS.has(k);
      })
      .sort((a, b) => Number(plannedKeys.has(itemKey(b.name))) - Number(plannedKeys.has(itemKey(a.name))))
      // An earlier night's leftovers are named as that night bought them.
      .map((x) => (j < i ? keys[j].get(itemKey(x.name))!.name : x.name));
  const score = (names: string[]) => names.reduce((s, n) => s + (plannedKeys.has(itemKey(n)) ? 2 : 1), 0);

  return meals.map((_, i) => {
    // Using up an earlier night's leftovers is the better story; nearest wins ties.
    const pick = (nights: number[]) => {
      let best: { j: number; names: string[] } | null = null;
      for (const j of nights) {
        const names = sharedWith(i, j);
        if (names.length && (!best || score(names) > score(best.names))) best = { j, names };
      }
      return best;
    };
    const best = pick(Array.from({ length: i }, (_, n) => i - 1 - n)) ??
      pick(Array.from({ length: meals.length - i - 1 }, (_, n) => i + 1 + n));
    if (!best) return null;
    return best.j < i
      ? `Uses the rest of ${label(best.j)}'s ${listOf(best.names.slice(0, 2))}`
      : `Shares the ${listOf(best.names.slice(0, 2))} with ${label(best.j)}`;
  });
}

/** "Uses up your spinach, feta and eggs", from what they said they have. */
export function usesUp(meal: Meal, have: string[]): string | null {
  const haveKeys = have.map(itemKey).filter(Boolean);
  const used = meal.ingredients
    .filter((i) => {
      const k = itemKey(i.name);
      return haveKeys.some((h) => h === k || h.includes(k) || k.includes(h));
    })
    .map((i) => i.name);
  return used.length ? `Uses up your ${listOf(used, 3)}` : null;
}
