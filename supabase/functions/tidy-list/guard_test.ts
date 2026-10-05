import assert from "node:assert/strict";
import { test } from "node:test";
import { safeFix, safeMerge, soundsUnsure, words } from "./guard.ts";

test("real duplicates merge", () => {
  assert.ok(safeMerge(["Chicken", "Chicken thighs"], "Chicken thighs"));
  assert.ok(safeMerge(["Avocado", "avocados"], "Avocados"));
  assert.ok(safeMerge(["Scallions", "Green onions"], "Green onions"));
  assert.ok(safeMerge(["Cilantro", "Fresh coriander"], "Cilantro"));
  assert.ok(safeMerge(["Tomatoes", "Large tomatoes", "tomato"], "Tomatoes"));
});

test("the merges from the bug report are refused", () => {
  assert.ok(!safeMerge(["Green onion", "Red onion"], "Green onions")); // different products
  assert.ok(!safeMerge(["Eggs", "Ramen"], "Eggs")); // unrelated
  assert.ok(!safeMerge(["Greek yogurt", "Spinach"], "Greek yogurt"));
});

test("product-changing words block a merge even when one name contains the other", () => {
  assert.ok(!safeMerge(["Milk", "Oat milk"], "Oat milk"));
  assert.ok(!safeMerge(["Onion", "Red onion"], "Red onion"));
  assert.ok(!safeMerge(["Potatoes", "Sweet potatoes"], "Sweet potatoes"));
  assert.ok(!safeMerge(["Lemons", "Limes"], "Lemons"));
  assert.ok(!safeMerge(["Chicken breasts", "Chicken thighs"], "Chicken thighs"));
});

test("the merged name can't introduce something new", () => {
  assert.ok(!safeMerge(["Chicken", "Chicken thighs"], "Chicken drumsticks"));
  assert.ok(!safeMerge(["Rice", "rice"], "Jasmine rice"));
});

test("fixes: spelling and a quantity stuck in the name", () => {
  assert.ok(safeFix("Tomatos", "Tomatoes"));
  assert.ok(safeFix("Brocoli", "Broccoli"));
  assert.ok(safeFix("Eggs 12", "Eggs"));
  assert.ok(!safeFix("Eggs", "Ramen"));
  assert.ok(!safeFix("Spinach", "Baby spinach and kale"));
});

test("self-corrections leaking into the output", () => {
  assert.ok(soundsUnsure("No-wait. incorrect merge attempt"));
  assert.ok(soundsUnsure("Same item", "Actually these differ"));
  assert.ok(!soundsUnsure("Same item, two spellings", "Green onions"));
  assert.ok(!soundsUnsure("Fixed a spelling mistake", "No-salt butter"));
});

test("word normalisation", () => {
  assert.deepEqual([...words("Fresh berries")], ["berry"]);
  assert.deepEqual([...words("2 lb Potatoes")], ["potato"]);
});
