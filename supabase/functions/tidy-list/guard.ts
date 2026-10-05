// Deterministic sanity checks on Tidy up proposals. The model is good at
// spotting real duplicates but, unchecked, also "merges" things that merely
// sit together (eggs + ramen, yogurt + spinach) or differ in a way that
// matters (green vs red onion). Silence is better than a bad suggestion, so
// anything that fails here is dropped before the user sees it.

/** Words that don't change what you'd buy. */
const FILLER = new Set([
  "fresh", "large", "small", "medium", "big", "organic", "whole", "of", "a", "an", "the", "and",
  "pack", "package", "bag", "box", "can", "canned", "jar", "bottle", "bunch", "head", "lb", "lbs", "oz", "g", "kg",
]);

/** Words that make it a different product: never merge across them. */
const VARIANT = new Set([
  "red", "green", "yellow", "white", "black", "brown", "purple", "orange", "golden", "pink",
  "oat", "almond", "soy", "coconut", "rice", "cashew", "lactose", "skim", "sweet", "sour", "hot",
  "smoked", "diet", "decaf", "unsalted", "salted", "baby", "wild", "greek",
]);

/** True synonyms, mapped to one spelling. */
const SYNONYMS: [RegExp, string][] = [
  [/\bscallions?\b/g, "green onion"],
  [/\bspring onions?\b/g, "green onion"],
  [/\bcoriander\b/g, "cilantro"],
  [/\bgarbanzo(?: beans?)?\b/g, "chickpea"],
  [/\bcourgettes?\b/g, "zucchini"],
  [/\baubergines?\b/g, "eggplant"],
  [/\bcapsicums?\b/g, "bell pepper"],
];

function singular(w: string): string {
  if (w.endsWith("ies") && w.length > 4) return w.slice(0, -3) + "y";
  if (/(?:oes|ches|shes|xes|sses)$/.test(w)) return w.slice(0, -2);
  if (w.endsWith("s") && !w.endsWith("ss") && w.length > 3) return w.slice(0, -1);
  return w;
}

/** The set of meaningful words in an item name. */
export function words(name: string): Set<string> {
  let n = name.toLowerCase();
  for (const [re, to] of SYNONYMS) n = n.replace(re, to);
  return new Set(
    n.split(/[^a-z]+/).filter((w) => w && !FILLER.has(w)).map(singular),
  );
}

const subset = (a: Set<string>, b: Set<string>) => [...a].every((w) => b.has(w));

/**
 * A merge is safe when every item names the same product as the most
 * specific one ("Chicken" ⊆ "Chicken thighs"), no product-changing word
 * (colour, plant milk, "sweet"…) is gained along the way, and the merged
 * name doesn't introduce anything new.
 */
export function safeMerge(names: string[], result: string): boolean {
  const sets = names.map(words);
  if (sets.some((s) => s.size === 0)) return false;
  const most = sets.reduce((a, b) => (b.size > a.size ? b : a));
  for (const s of sets) {
    if (!subset(s, most)) return false;
    for (const w of most) if (!s.has(w) && VARIANT.has(w)) return false;
  }
  const out = words(result);
  return out.size > 0 && subset(out, most) && subset(most, out);
}

function editDistance(a: string, b: string): number {
  const dp = Array.from({ length: b.length + 1 }, (_, i) => i);
  for (let i = 1; i <= a.length; i++) {
    let prev = dp[0];
    dp[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const tmp = dp[j];
      dp[j] = Math.min(dp[j] + 1, dp[j - 1] + 1, prev + (a[i - 1] === b[j - 1] ? 0 : 1));
      prev = tmp;
    }
  }
  return dp[b.length];
}

/**
 * A fix is safe when it's a small spelling change ("Tomatos" → "Tomatoes") or
 * just pulls a quantity out of the name ("Eggs 12" → "Eggs").
 */
export function safeFix(before: string, after: string): boolean {
  const a = before.toLowerCase().trim(), b = after.toLowerCase().trim();
  if (!b) return false;
  const lettersOnly = (s: string) => s.replace(/[^a-z ]+/g, " ").replace(/\s+/g, " ").trim();
  if (lettersOnly(a) === lettersOnly(b)) return true; // quantity pulled out
  return editDistance(a, b) <= Math.max(2, Math.floor(Math.max(a.length, b.length) / 4));
}

/** The model second-guessing itself in the output ("No-wait, incorrect merge"). */
export function soundsUnsure(...texts: string[]): boolean {
  return texts.some((t) => /\b(?:no[-\s]?wait|wait,|incorrect|actually|oops|sorry|not sure|scratch that|ignore this)\b/i.test(t));
}
