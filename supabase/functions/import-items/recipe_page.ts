// Pulls a recipe out of a fetched web page. Prefers schema.org Recipe JSON-LD
// (name + recipeIngredient), which most recipe sites publish for search
// engines; otherwise reduces the HTML to readable text for the model.
//
// Pure TypeScript so it's testable under Node.

export type PageRecipe = { name: string | null; ingredients: string[] };

const MAX_INGREDIENTS = 80;

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  frac12: "½",
  frac14: "¼",
  frac34: "¾",
  frac13: "⅓",
  frac23: "⅔",
  frac18: "⅛",
  deg: "°",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
  ndash: "–",
  mdash: "—",
  hellip: "…",
  eacute: "é",
  egrave: "è",
  ntilde: "ñ",
  uuml: "ü",
  ouml: "ö",
  auml: "ä",
  ccedil: "ç",
  times: "×",
};

export function decodeEntities(s: string): string {
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z][a-z0-9]*);/gi, (whole, code: string) => {
    if (code[0] === "#") {
      const n = code[1] === "x" || code[1] === "X" ? parseInt(code.slice(2), 16) : parseInt(code.slice(1), 10);
      try {
        return Number.isFinite(n) && n > 0 ? String.fromCodePoint(n) : whole;
      } catch {
        return whole;
      }
    }
    return NAMED_ENTITIES[code.toLowerCase()] ?? whole;
  });
}

/** Strips tags and entities from a JSON-LD string value and tidies whitespace. */
function cleanText(s: string): string {
  // Some sites double-encode (&amp;frac12;), so decode twice.
  return decodeEntities(decodeEntities(s.replace(/<[^>]*>/g, " ")))
    .replace(/\s+/g, " ")
    .trim();
}

function parseJsonLoosely(raw: string): unknown {
  const trimmed = raw
    .trim()
    .replace(/^<!--|-->$/g, "")
    .replace(/^\s*\/\/\s*<!\[CDATA\[|\/\/\s*\]\]>\s*$/g, "")
    .replace(/;\s*$/, "")
    .trim();
  try {
    return JSON.parse(trimmed);
  } catch {
    // Raw newlines/tabs inside strings are a common JSON-LD bug; outside
    // strings they're just whitespace, so replacing them is harmless.
    try {
      return JSON.parse(trimmed.replace(/[\u0000-\u001f]+/g, " "));
    } catch {
      return undefined;
    }
  }
}

function isRecipeType(t: unknown): boolean {
  const types = Array.isArray(t) ? t : [t];
  return types.some((x) => typeof x === "string" && /(^|[/#:])recipe$/i.test(x.trim()));
}

function findRecipeNode(node: unknown, depth = 0): Record<string, unknown> | null {
  if (depth > 8 || node === null || typeof node !== "object") return null;
  if (Array.isArray(node)) {
    for (const n of node) {
      const found = findRecipeNode(n, depth + 1);
      if (found) return found;
    }
    return null;
  }
  const obj = node as Record<string, unknown>;
  if (isRecipeType(obj["@type"])) return obj;
  for (const v of Object.values(obj)) {
    const found = findRecipeNode(v, depth + 1);
    if (found) return found;
  }
  return null;
}

function stringsOf(v: unknown): string[] {
  if (typeof v === "string") return [v];
  if (Array.isArray(v)) return v.flatMap(stringsOf);
  if (v && typeof v === "object") {
    const o = v as Record<string, unknown>;
    // Occasionally ingredients are PropertyValue/HowToSupply objects.
    for (const key of ["text", "name", "value"]) {
      if (typeof o[key] === "string") return [o[key] as string];
    }
  }
  return [];
}

/** The first schema.org Recipe with ingredients found in the page's JSON-LD, or null. */
export function extractJsonLdRecipe(html: string): PageRecipe | null {
  const re = /<script\b[^>]*\btype\s*=\s*["']?application\/ld\+json["']?[^>]*>([\s\S]*?)<\/script\s*>/gi;
  for (const m of html.matchAll(re)) {
    const node = findRecipeNode(parseJsonLoosely(m[1]));
    if (!node) continue;
    const recipe = recipeFromNode(node);
    if (recipe) return recipe;
  }
  return null;
}

/** Same as extractJsonLdRecipe, for a page that is JSON itself. */
export function extractJsonRecipe(json: string): PageRecipe | null {
  const node = findRecipeNode(parseJsonLoosely(json));
  return node ? recipeFromNode(node) : null;
}

function recipeFromNode(node: Record<string, unknown>): PageRecipe | null {
  const ingredients = stringsOf(node.recipeIngredient ?? node.ingredients)
    .map(cleanText)
    .filter((s) => s.length > 0 && s.length <= 300)
    .slice(0, MAX_INGREDIENTS);
  if (ingredients.length === 0) return null;
  const name = stringsOf(node.name).map(cleanText).find((s) => s.length > 0) ?? null;
  return { name: name ? name.slice(0, 120) : null, ingredients };
}

/** The page's <title> (or og:title), cleaned, or null. */
export function pageTitle(html: string): string | null {
  const og = /<meta\b[^>]*property\s*=\s*["']og:title["'][^>]*content\s*=\s*["']([^"']*)["']/i.exec(html);
  const t = og?.[1] ?? /<title\b[^>]*>([\s\S]*?)<\/title>/i.exec(html)?.[1];
  const cleaned = t ? cleanText(t) : "";
  return cleaned ? cleaned.slice(0, 160) : null;
}

/** Visible-ish text of an HTML page, with block elements on their own lines. */
export function htmlToText(html: string, maxChars = 14000): string {
  const text = html
    .replace(/<!--[\s\S]*?-->/g, " ")
    .replace(/<(script|style|noscript|svg|template|iframe|head|nav|footer)\b[\s\S]*?<\/\1\s*>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|h[1-6]|tr|section|article|ul|ol|header)\s*>/gi, "\n")
    .replace(/<li\b[^>]*>/gi, "\n- ")
    .replace(/<[^>]+>/g, " ");
  return decodeEntities(text)
    .replace(/[ \t\f\v ]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
    .slice(0, maxChars);
}
