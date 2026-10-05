// Run: node --test supabase/tests/   (Node 23+ runs TypeScript directly)
import { test } from "node:test";
import assert from "node:assert/strict";

import {
  decodeEntities,
  extractJsonLdRecipe,
  extractJsonRecipe,
  htmlToText,
  pageTitle,
} from "../functions/import-items/recipe_page.ts";

const ld = (json: unknown, attrs = 'type="application/ld+json"') =>
  `<script ${attrs}>${typeof json === "string" ? json : JSON.stringify(json)}</script>`;

test("finds a top-level Recipe", () => {
  const html = `<html><head>${ld({
    "@context": "https://schema.org",
    "@type": "Recipe",
    name: "Lemon Chicken",
    recipeIngredient: ["2 lb chicken thighs", "1 lemon"],
  })}</head><body></body></html>`;
  assert.deepEqual(extractJsonLdRecipe(html), { name: "Lemon Chicken", ingredients: ["2 lb chicken thighs", "1 lemon"] });
});

test("finds a Recipe inside @graph alongside other types", () => {
  const html = ld({
    "@context": "https://schema.org",
    "@graph": [
      { "@type": "Organization", name: "Site" },
      { "@type": "WebPage", name: "Page" },
      { "@type": ["Recipe", "NewsArticle"], name: "Pad Thai", recipeIngredient: ["8 oz rice noodles"] },
    ],
  });
  assert.equal(extractJsonLdRecipe(html)?.name, "Pad Thai");
});

test("finds a Recipe in a top-level array and in mainEntity", () => {
  assert.equal(
    extractJsonLdRecipe(ld([{ "@type": "BreadcrumbList" }, { "@type": "Recipe", name: "A", recipeIngredient: ["x"] }]))?.name,
    "A",
  );
  assert.equal(
    extractJsonLdRecipe(ld({ "@type": "WebPage", mainEntity: { "@type": "Recipe", name: "B", recipeIngredient: ["y"] } }))?.name,
    "B",
  );
});

test("accepts schema.org URL types and legacy 'ingredients'", () => {
  const r = extractJsonLdRecipe(ld({ "@type": "http://schema.org/Recipe", name: "Old", ingredients: ["1 cup flour"] }));
  assert.deepEqual(r?.ingredients, ["1 cup flour"]);
});

test("skips Recipe-less and ingredient-less blocks, uses a later one", () => {
  const html =
    ld({ "@type": "Organization", name: "x" }) +
    ld({ "@type": "Recipe", name: "Empty", recipeIngredient: [] }) +
    ld({ "@type": "Recipe", name: "Real", recipeIngredient: ["eggs"] });
  assert.equal(extractJsonLdRecipe(html)?.name, "Real");
});

test("decodes entities and strips tags in ingredient lines", () => {
  const r = extractJsonLdRecipe(
    ld({
      "@type": "Recipe",
      name: "Mac &amp; Cheese",
      recipeIngredient: ["&frac12; cup <b>cheddar</b>", "1 tsp cr&egrave;me", "2 &amp;frac14; oz butter", "  ", "salt &#38; pepper", "&#x2153; cup milk"],
    }),
  );
  assert.equal(r?.name, "Mac & Cheese");
  assert.deepEqual(r?.ingredients, ["½ cup cheddar", "1 tsp crème", "2 ¼ oz butter", "salt & pepper", "⅓ cup milk"]);
});

test("tolerates sloppy JSON-LD (raw newlines, comments, trailing semicolon, single-quoted type attr)", () => {
  const raw = `<!--{"@type":"Recipe","name":"Soup","recipeIngredient":["1 onion
chopped","2 carrots"]};-->`;
  const r = extractJsonLdRecipe(ld(raw, "type='application/ld+json' class=\"yoast\""));
  assert.deepEqual(r, { name: "Soup", ingredients: ["1 onion chopped", "2 carrots"] });
});

test("ignores invalid JSON and non-JSON-LD scripts", () => {
  const html =
    ld("{not json") +
    `<script type="application/json">{"@type":"Recipe","name":"Nope","recipeIngredient":["x"]}</script>` +
    `<script>var x = {"@type":"Recipe"}</script>`;
  assert.equal(extractJsonLdRecipe(html), null);
});

test("returns null when there's no JSON-LD", () => {
  assert.equal(extractJsonLdRecipe("<html><body><h1>Pasta</h1></body></html>"), null);
});

test("handles ingredient objects and name arrays", () => {
  const r = extractJsonLdRecipe(ld({ "@type": "Recipe", name: ["Stew", "Alt"], recipeIngredient: [{ text: "1 lb beef" }, "2 potatoes"] }));
  assert.deepEqual(r, { name: "Stew", ingredients: ["1 lb beef", "2 potatoes"] });
});

test("caps ingredient count", () => {
  const r = extractJsonLdRecipe(ld({ "@type": "Recipe", name: "Big", recipeIngredient: Array.from({ length: 200 }, (_, i) => `item ${i}`) }));
  assert.equal(r?.ingredients.length, 80);
});

test("extractJsonRecipe reads a JSON page", () => {
  assert.equal(extractJsonRecipe(JSON.stringify({ "@type": "Recipe", name: "J", recipeIngredient: ["a"] }))?.name, "J");
  assert.equal(extractJsonRecipe("[]"), null);
});

test("htmlToText keeps content, drops scripts/styles, puts list items on lines", () => {
  const text = htmlToText(`<html><head><title>T</title><style>.a{}</style></head><body>
    <script>alert("x")</script><nav>Home | About</nav>
    <h1>Best&nbsp;Chili</h1><ul><li>1 lb beef</li><li>1 can beans</li></ul><p>Cook it.</p>
    <!-- hidden --></body></html>`);
  assert.ok(text.includes("Best Chili"));
  assert.ok(text.includes("- 1 lb beef\n"));
  assert.ok(text.includes("- 1 can beans"));
  assert.ok(text.includes("Cook it."));
  for (const gone of ["alert", ".a{}", "Home | About", "hidden"]) assert.ok(!text.includes(gone), gone);
});

test("htmlToText caps length", () => {
  assert.equal(htmlToText(`<p>${"a".repeat(50000)}</p>`, 1000).length, 1000);
});

test("pageTitle prefers og:title", () => {
  assert.equal(pageTitle(`<title>Site | Tacos</title><meta property="og:title" content="Fish Tacos">`), "Fish Tacos");
  assert.equal(pageTitle(`<title> Tacos &amp; More </title>`), "Tacos & More");
  assert.equal(pageTitle(`<p>no title</p>`), null);
});

test("decodeEntities leaves unknown entities alone", () => {
  assert.equal(decodeEntities("&bogus; &amp; &#0; &#xFFFFFFF;"), "&bogus; & &#0; &#xFFFFFFF;");
});
