// node --experimental-strip-types supabase/functions/plan-meals/notes_test.ts
import assert from "node:assert/strict";
import { test } from "node:test";
import { itemKey, type Meal, reuseNotes, usesUp } from "./notes.ts";

const meal = (name: string, day: string, items: [string, boolean][]): Meal => ({
  name,
  pitch: "",
  minutes: 30,
  effort: "easy",
  appliance: null,
  reuse_note: null,
  day,
  ingredients: items.map(([n, perishable]) => ({ name: n, quantity: null, perishable })),
});

test("itemKey folds plurals and punctuation", () => {
  assert.equal(itemKey("Limes"), itemKey("lime"));
  assert.equal(itemKey("Tomatoes"), itemKey("tomato"));
  assert.equal(itemKey("Berries"), itemKey("berry"));
  assert.equal(itemKey("Green  onions"), "green onion");
  assert.equal(itemKey("Swiss"), "swiss"); // not "swis"... "ss" is kept
});

test("notes name only what really overlaps", () => {
  const week = [
    meal("Tacos", "Monday", [["Cilantro", true], ["Lime", true], ["Yellow onion", true], ["Tortillas", false]]),
    meal("Pasta", "Tuesday", [["Basil", true], ["Yellow onion", true], ["Spaghetti", false]]),
    meal("Rice bowls", "Thursday", [["Cilantro", true], ["Limes", true], ["Basil", true], ["Rice", false]]),
    meal("Soup", "Friday", [["Rice", false], ["Stock", false]]),
  ];
  assert.deepEqual(reuseNotes(week, ["Cilantro"]), [
    "Shares the cilantro and lime with Thursday",
    "Shares the basil with Thursday", // the onion keeps for weeks: not worth a note
    "Uses the rest of Monday's cilantro and lime", // beats Tuesday's basil (more shared, cilantro planned)
    null, // rice isn't perishable
  ]);
});

test("nearest earlier night wins a tie", () => {
  const week = [
    meal("A", "Monday", [["Spinach", true]]),
    meal("B", "Tuesday", [["Spinach", true]]),
    meal("C", "Wednesday", [["Spinach", true]]),
  ];
  assert.equal(reuseNotes(week)[2], "Uses the rest of Tuesday's spinach");
});

test("usesUp matches loosely against what they have", () => {
  const m = meal("Frittata", "", [["Baby spinach", true], ["Feta cheese", true], ["Eggs", true], ["Milk", true]]);
  assert.equal(usesUp(m, ["spinach", "feta", "eggs"]), "Uses up your baby spinach, feta cheese and eggs");
  assert.equal(usesUp(m, ["half a cabbage"]), null);
});
