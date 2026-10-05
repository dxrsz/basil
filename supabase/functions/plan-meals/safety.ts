// A keyword safety net under the model for diets, allergies and dislikes.
// The prompt states the rules; this catches the times the model slips (an
// allergen in a garnish, "peanutless satay" for a nut allergy) so the planner
// can retry or drop the meal. Deliberately strict: a false alarm costs one
// retry, a miss could cost a trip to hospital. Pure functions (no Deno APIs):
//   node --experimental-strip-types supabase/functions/plan-meals/safety_test.ts

type Checkable = { name: string; ingredients: { name: string }[] };

const MEAT =
  "chicken|beef|pork|bacon|ham|sausages?|turkey|lamb|steaks?|prosciutto|pancetta|salami|pepperoni|chorizo|veal|duck|" +
  "venison|meatballs?|brisket|spare ribs|short ribs|lard|gelatine?";
const FISH = "fish|salmon|tuna|cod|tilapia|halibut|trout|sardines?|anchov(?:y|ies)|mackerel|haddock|bonito";
const SHELLFISH =
  "shrimps?|prawns?|crabs?|lobsters?|mussels?|clams?|scallops?|oysters?|crawfish|crayfish|langoustines?|calamari|squid|octopus";
const DAIRY =
  "milk|cheeses?|butter|cream|yog(?:h)?urt|ghee|paneer|feta|parmesan|mozzarella|cheddar|ricotta|mascarpone|" +
  "halloumi|burrata|brie|gruyere|queso|cotija|creme fraiche|buttermilk|custard";
const EGG = "eggs?|mayo|mayonnaise|meringue|aioli";
// Matched as substrings too, so "peanutless" and "almondy" are caught.
const NUTS = "peanuts?|almonds?|cashews?|walnuts?|pecans?|pistachios?|hazelnuts?|macadamias?|pine nuts?|brazil nuts?|" +
  "nuts?|nut butter|praline|marzipan|nutella|satay|pesto|frangipane";
const GLUTEN = "flour|bread|breadcrumbs|panko|pasta|spaghetti|penne|fusilli|linguine|fettuccine|lasagna|macaroni|orzo|" +
  "noodles?|ramen|udon|couscous|barley|bulgur|farro|seitan|wheat|tortillas?|pitas?|naan|baguettes?|buns?|croutons?|" +
  "pizza dough|pastry|crackers?|beer";
const ALCOHOL = "wine|beer|rum|vodka|whiskey|whisky|brandy|sherry|bourbon|tequila|sake|mirin";

/** Words that make a forbidden word fine: "coconut milk", "corn tortillas", "rice noodles". */
const SAFE_PREFIXES: Record<string, string> = {
  dairy: "coconut|oat|almond|soy|rice|cashew|vegan|plant[- ]based|dairy[- ]free|peanut|nut|apple",
  egg: "vegan|egg[- ]free|flax",
  gluten: "gluten[- ]free|rice|corn|chickpea|lentil|almond|coconut|buckwheat|tapioca|cassava|soba|glass|bean|zucchini",
  meat: "vegan|plant[- ]based|meatless|vegetarian|impossible|beyond",
  alcohol: "", // wine vinegar is handled below
};

function words(alternatives: string, prefixes = ""): RegExp {
  const guard = prefixes ? `(?<!(?:${prefixes})[ -])` : "";
  return new RegExp(`${guard}\\b(?:${alternatives})\\b`, "i");
}

const RULES: Record<string, RegExp[]> = {
  vegetarian: [words(MEAT, SAFE_PREFIXES.meat), words(FISH, SAFE_PREFIXES.meat), words(SHELLFISH)],
  vegan: [
    words(MEAT, SAFE_PREFIXES.meat),
    words(FISH, SAFE_PREFIXES.meat),
    words(SHELLFISH),
    words(DAIRY, SAFE_PREFIXES.dairy),
    words(EGG, SAFE_PREFIXES.egg),
    words("honey"),
  ],
  pescatarian: [words(MEAT, SAFE_PREFIXES.meat)],
  gluten_free: [words(GLUTEN, SAFE_PREFIXES.gluten)],
  dairy_free: [words(DAIRY, SAFE_PREFIXES.dairy)],
  nut_allergy: [words(NUTS), /(peanut|almond|cashew|walnut|pecan|pistachio|hazelnut|macadamia)/i],
  shellfish_allergy: [words(SHELLFISH)],
  halal: [words("pork|bacon|ham|prosciutto|pancetta|chorizo|salami|pepperoni|lard|gelatine?"), words(ALCOHOL)],
  kosher: [words("pork|bacon|ham|prosciutto|pancetta|chorizo|salami|pepperoni|lard"), words(SHELLFISH)],
};

function singular(w: string): string {
  const k = w.toLowerCase().trim();
  if (k.endsWith("ies")) return k.slice(0, -3) + "y";
  if (k.endsWith("oes")) return k.slice(0, -2);
  if (k.endsWith("s") && !k.endsWith("ss")) return k.slice(0, -1);
  return k;
}

/**
 * Why [meal] breaks the household's rules ("nut allergy: Peanutless satay"),
 * or an empty list when it's fine.
 */
export function violations(meal: Checkable, diets: string[], dislikes: string[]): string[] {
  // The name and ingredients, not the pitch: "no meat needed!" is fine.
  // Wine vinegar isn't alcohol for anyone's purposes.
  const texts = [meal.name, ...meal.ingredients.map((i) => i.name)]
    .map((t) => t.replace(/\b(?:rice |red |white )?wine vinegar\b/gi, "vinegar"));
  const out: string[] = [];
  for (const diet of diets) {
    for (const rule of RULES[diet] ?? []) {
      const hit = texts.find((t) => rule.test(t));
      if (hit) {
        out.push(`${diet.replace(/_/g, " ")}: ${hit}`);
        break;
      }
    }
    // Kosher: never meat with dairy in one meal.
    if (diet === "kosher") {
      const meat = texts.some((t) => words(MEAT, SAFE_PREFIXES.meat).test(t));
      const dairy = texts.some((t) => words(DAIRY, SAFE_PREFIXES.dairy).test(t));
      if (meat && dairy) out.push("kosher: meat with dairy");
    }
  }
  for (const d of dislikes) {
    const key = singular(d);
    if (key.length < 3) continue;
    const re = new RegExp(`\\b${key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:e?s)?\\b`, "i");
    const hit = texts.find((t) => re.test(t));
    if (hit) out.push(`dislikes ${d}: ${hit}`);
  }
  return out;
}
