import '../../models/models.dart';
import '../../util/item_merge.dart';

/// How long a "Got it" answer is trusted before Lamar asks again. Staples
/// pinned as "always have" never expire.
const pantryMemory = Duration(days: 30);

// Things most kitchens keep on hand, matched against the end of the
// normalised name ("extra virgin olive oil" ends in "oil"), so "bell pepper"
// or "flour tortillas" don't count.
final _stapleEndings = const [
  'oil',
  'salt',
  'vinegar',
  'soy sauce',
  'flour',
  'sugar',
  'rice',
  'baking soda',
  'baking powder',
  'cornstarch',
  'garlic powder',
  'onion powder',
  'chili powder',
  'curry powder',
  'cumin',
  'paprika',
  'cinnamon',
  'oregano',
  'nutmeg',
  'turmeric',
  'cayenne',
  'red pepper flakes',
  'chili flakes',
  'bay leaves',
  'seasoning',
  'vanilla extract',
  'honey',
  'ketchup',
  'mustard',
  'mayo',
  'mayonnaise',
  'hot sauce',
  'sriracha',
  'fish sauce',
  'worcestershire sauce',
  'peppercorns',
].map(normalizeItemName).toSet();

// Only these exact names, since plenty of things end in "pepper" or "water".
final _stapleExact = const [
  'pepper',
  'black pepper',
  'white pepper',
  'ground pepper',
  'ground black pepper',
  'cayenne pepper',
  'salt and pepper',
  'water',
  'ice',
  'cooking spray',
].map(normalizeItemName).toSet();

/// True for things Lamar assumes a kitchen already has (oil, salt, spices,
/// soy sauce, flour, sugar, rice, condiments…).
bool isPantryStaple(String name) {
  final key = normalizeItemName(name);
  if (key.isEmpty) return false;
  if (_stapleExact.contains(key)) return true;
  final words = key.split(' ');
  for (var i = 0; i < words.length; i++) {
    if (_stapleEndings.contains(words.sublist(i).join(' '))) return true;
  }
  return false;
}

enum PantryReason {
  /// Nothing known: add it.
  none,

  /// On the curated staples list.
  staple,

  /// Someone said they had it within [pantryMemory].
  remembered,

  /// Pinned as "always have".
  always,

  /// They had it, but longer ago than [pantryMemory]: ask again.
  stale,
}

class PantryGuess {
  const PantryGuess(this.have, this.reason, [this.confirmedAt]);

  final bool have;
  final PantryReason reason;
  final DateTime? confirmedAt;
}

/// Whether the household probably already has [name].
PantryGuess guessPantry(String name, Map<String, PantryStaple> memoryByKey, DateTime now) {
  final m = memoryByKey[normalizeItemName(name)];
  if (m != null && m.always) return PantryGuess(true, PantryReason.always, m.confirmedAt);
  if (m != null && now.difference(m.confirmedAt) < pantryMemory) {
    return PantryGuess(true, PantryReason.remembered, m.confirmedAt);
  }
  if (isPantryStaple(name)) return const PantryGuess(true, PantryReason.staple);
  if (m != null) return PantryGuess(false, PantryReason.stale, m.confirmedAt);
  return const PantryGuess(false, PantryReason.none);
}

/// One ingredient in the "Got this already?" review.
class MealReviewRow {
  MealReviewRow({required this.name, required this.quantity, required this.guess, this.onList, this.combined})
    : add = onList != null || !guess.have;

  final String name;
  final String? quantity;
  final PantryGuess guess;

  /// The unchecked list item this would merge into, if any.
  final Item? onList;

  /// The merged quantity it would end up with, if it merges.
  final String? combined;

  /// The user's choice: true = put it on the list, false = "Got it".
  bool add;
}

/// Works out which of [recipe]'s ingredients to ask about, mirroring what
/// `add_recipe_to_list` will do: ingredients already on the list from this
/// meal aren't asked about (the server skips them), and repeated lines are
/// combined. Ones already on the list to get will merge (quantities added),
/// and ones only in the cart get a fresh item, so both default to "add".
List<MealReviewRow> buildMealReview({
  required Recipe recipe,
  required List<Item> items,
  required List<PantryStaple> pantry,
  required DateTime now,
}) {
  final memory = {for (final p in pantry) p.nameKey: p};
  final unchecked = <String, Item>{};
  for (final i in items) {
    if (!i.checked) unchecked.putIfAbsent(normalizeItemName(i.name), () => i);
  }
  final fromThisMeal = {
    for (final i in items)
      if (!i.checked && i.recipeIds.contains(recipe.id)) normalizeItemName(i.name),
  };

  // Combine repeated lines first, keeping the first spelling.
  final order = <String>[];
  final names = <String, String>{};
  final quantities = <String, String?>{};
  for (final ing in recipe.ingredients) {
    final key = normalizeItemName(ing.name);
    if (key.isEmpty) continue;
    if (names.containsKey(key)) {
      quantities[key] = combineQuantities(quantities[key], ing.quantity);
    } else {
      order.add(key);
      names[key] = ing.name.trim();
      quantities[key] = ing.quantity?.trim().isEmpty ?? true ? null : ing.quantity!.trim();
    }
  }

  return [
    for (final key in order)
      if (!fromThisMeal.contains(key))
        MealReviewRow(
          name: names[key]!,
          quantity: quantities[key],
          guess: guessPantry(names[key]!, memory, now),
          onList: unchecked[key],
          combined: unchecked[key] == null ? null : combineQuantities(unchecked[key]!.quantity, quantities[key]),
        ),
  ];
}

/// What to tell the server once the review is confirmed.
({List<String> skip, List<String> have, List<String> forget}) reviewAnswers(List<MealReviewRow> rows) {
  final skip = <String>[], have = <String>[], forget = <String>[];
  for (final r in rows) {
    if (!r.add) {
      skip.add(r.name);
      // Curated staples are assumed anyway; remember everything else (and
      // refresh anything we already remembered).
      if (r.guess.reason != PantryReason.staple || r.guess.confirmedAt != null) have.add(r.name);
    } else if (r.onList == null && r.guess.confirmedAt != null) {
      // They had it before but need it now.
      forget.add(r.name);
    }
  }
  return (skip: skip, have: have, forget: forget);
}
