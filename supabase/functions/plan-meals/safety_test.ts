// node --experimental-strip-types supabase/functions/plan-meals/safety_test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import { violations } from "./safety.ts";

const meal = (name: string, ...ingredients: string[]) => ({ name, ingredients: ingredients.map((n) => ({ name: n })) });

test("nut allergy catches allergens in names, garnishes and sauces", () => {
  assert.ok(violations(meal("Thai Peanutless Satay", "Tofu"), ["nut_allergy"], []).length);
  assert.ok(violations(meal("Pasta", "Basil pesto"), ["nut_allergy"], []).length);
  assert.ok(violations(meal("Granola", "Toasted almonds"), ["nut_allergy"], []).length);
  assert.ok(violations(meal("Salad", "Pine nuts"), ["nut_allergy"], []).length);
  for (const fine of ["Coconut milk", "Nutmeg", "Butternut squash", "Doughnut", "Nutritional yeast"]) {
    assert.deepEqual(violations(meal("Curry", fine), ["nut_allergy"], []), [], fine);
  }
});

test("vegetarian, vegan, pescatarian", () => {
  assert.ok(violations(meal("Pad thai", "Rice noodles", "Fish sauce"), ["vegetarian"], []).length);
  assert.ok(violations(meal("Tacos", "Chicken thighs"), ["vegetarian"], []).length);
  assert.deepEqual(violations(meal("Bean chili", "Black beans", "Cheddar", "Eggs"), ["vegetarian"], []), []);
  assert.deepEqual(violations(meal("Burgers", "Plant-based beef", "Eggplant"), ["vegetarian"], []), []);
  assert.ok(violations(meal("Frittata", "Eggs"), ["vegan"], []).length);
  assert.ok(violations(meal("Pasta", "Parmesan"), ["vegan"], []).length);
  assert.deepEqual(violations(meal("Curry", "Coconut milk", "Peanut butter", "Tofu"), ["vegan"], []), []);
  assert.deepEqual(violations(meal("Fish tacos", "Cod", "Corn tortillas"), ["pescatarian"], []), []);
  assert.ok(violations(meal("Fish tacos", "Cod", "Bacon"), ["pescatarian"], []).length);
});

test("gluten-free and dairy-free respect safe versions", () => {
  assert.ok(violations(meal("Tacos", "Flour tortillas"), ["gluten_free"], []).length);
  assert.ok(violations(meal("Spaghetti bolognese", "Spaghetti"), ["gluten_free"], []).length);
  assert.deepEqual(
    violations(meal("Tacos", "Corn tortillas", "Rice noodles", "Gluten-free pasta"), ["gluten_free"], []),
    [],
  );
  assert.ok(violations(meal("Mac", "Cheddar cheese"), ["dairy_free"], []).length);
  assert.deepEqual(violations(meal("Curry", "Coconut cream", "Oat milk"), ["dairy_free"], []), []);
});

test("shellfish, halal, kosher", () => {
  assert.ok(violations(meal("Paella", "Shrimp"), ["shellfish_allergy"], []).length);
  assert.ok(violations(meal("Carbonara", "Pancetta"), ["halal"], []).length);
  assert.ok(violations(meal("Risotto", "White wine"), ["halal"], []).length);
  assert.deepEqual(violations(meal("Slaw", "Rice wine vinegar"), ["halal"], []), []);
  assert.ok(violations(meal("Cheeseburger", "Ground beef", "Cheddar"), ["kosher"], []).length);
  assert.deepEqual(violations(meal("Salmon bake", "Salmon", "Butter"), ["kosher"], []), []);
});

test("dislikes match plurals, whole words only", () => {
  assert.ok(violations(meal("Stroganoff", "Cremini mushrooms"), [], ["Mushrooms"]).length);
  assert.ok(violations(meal("Pizza", "Kalamata olives"), [], ["olives"]).length);
  assert.ok(violations(meal("Salsa", "Tomatoes"), [], ["tomato"]).length);
  assert.equal(violations(meal("Toast", "Peas"), [], ["pea"]).length, 1);
  assert.deepEqual(violations(meal("Toast", "Peanut butter"), [], ["pea"]), []);
});
